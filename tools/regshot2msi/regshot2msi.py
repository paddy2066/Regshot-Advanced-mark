#!/usr/bin/env python3
"""
regshot2msi - convert a Regshot Advanced "UNL" capture into a WiX source file (.wxs)
that compiles to a Windows Installer package (.msi).

Workflow
--------
    1. In Regshot Advanced, take the 1st shot, run the installer .exe, take the 2nd shot.
    2. Compare and export the difference as a "UNL" file (Templates/unl.tpl output).
    3. Run this converter:            python regshot2msi.py capture.unl -o app.wxs
    4. Compile with the WiX Toolset:  wix build app.wxs -o app.msi
       (WiX v4/v5:  dotnet tool install --global wix)

The "UNL" format is Regshot's explicitly machine-parsable output. Added items
(registry keys/values, files, directories) are recorded as commented lines
starting with ';' and, for pure additions, a '+' after the '=' sign, e.g.:

    ; Registry=+"HKEY_LOCAL_MACHINE\\Software\\Foo","Bar"=dword:0000000a
    ; Registry=+"HKLM\\Software\\Foo"
    ; File=+"C:\\Program Files\\Foo\\bar.dll"
    ; Directory=+"C:\\Program Files\\Foo"

Uncommented lines are *removals* (the uninstall direction) and are ignored when
building an install package.

Registry value data uses the standard Windows .reg encoding, so the type is
recoverable from its prefix:
    "text"        -> REG_SZ          -> WiX Type="string"
    dword:0000000a-> REG_DWORD       -> WiX Type="integer"
    hex:xx,xx     -> REG_BINARY      -> WiX Type="binary"
    hex(2):xx,xx  -> REG_EXPAND_SZ   -> WiX Type="expandable"
    hex(7):xx,xx  -> REG_MULTI_SZ    -> WiX Type="multiString"
    hex(b):...    -> REG_QWORD       -> WiX Type="binary" (MSI has no qword reg type)
    hex(0):       -> REG_NONE        -> WiX Type="binary"

Limitations (v1)
----------------
  * Files are staged into the MSI from their captured absolute paths, which must
    still exist when 'wix build' runs (same assumption the built-in NSIS/Inno
    exports make). Use --strip-prefix to control where they install.
  * Registry key/value names are assumed not to contain embedded double quotes.
  * REG_QWORD / REG_NONE are emitted as binary (Windows Installer has no native
    registry type for them).

This tool is decoupled from the Regshot GUI: it reads a file the tool already
produces and needs no changes to the C application.
"""

import argparse
import binascii
import os
import re
import sys
import uuid
import xml.sax.saxutils as sax

# Deterministic namespace so the same title always yields the same UpgradeCode.
_UPGRADE_NS = uuid.UUID("6f9619ff-8b86-d011-b42d-00c04fc964ff")

# Map Regshot / .reg root names (long and short) to WiX Root attribute values.
_ROOT_MAP = {
    "HKLM": "HKLM", "HKEY_LOCAL_MACHINE": "HKLM",
    "HKCU": "HKCU", "HKEY_CURRENT_USER": "HKCU",
    "HKU": "HKU",   "HKEY_USERS": "HKU",
    "HKCR": "HKCR", "HKEY_CLASSES_ROOT": "HKCR",
    "HKMU": "HKMU",
}


class ConversionError(Exception):
    pass


# ---------------------------------------------------------------------------
# UNL parsing
# ---------------------------------------------------------------------------

class Change:
    """One install action recovered from the capture."""
    __slots__ = ("kind", "root", "key", "name", "vtype", "vdata", "path")

    def __init__(self, kind, root=None, key=None, name=None,
                 vtype=None, vdata=None, path=None):
        self.kind = kind          # 'regkey' | 'regval' | 'file' | 'dir'
        self.root = root
        self.key = key
        self.name = name          # registry value name ("" = default value)
        self.vtype = vtype        # WiX registry type
        self.vdata = vdata        # parsed python value (str, int, bytes, or list[str])
        self.path = path          # file / directory absolute path


def _split_root(fullkey):
    """Split 'HKLM\\Software\\Foo' -> ('HKLM', 'Software\\Foo')."""
    parts = fullkey.split("\\", 1)
    head = parts[0].upper()
    root = _ROOT_MAP.get(head)
    if root is None:
        raise ConversionError("unknown registry root: %r" % fullkey)
    subkey = parts[1] if len(parts) > 1 else ""
    return root, subkey


def _parse_reg_data(data):
    """Parse a .reg-style value payload into (wix_type, python_value)."""
    data = data.strip()
    if data == "":
        return "string", ""
    if data.startswith('"'):
        # REG_SZ - strip surrounding quotes and unescape.
        inner = data[1:]
        if inner.endswith('"'):
            inner = inner[:-1]
        inner = inner.replace('\\"', '"').replace("\\\\", "\\")
        return "string", inner
    if data.startswith("dword:"):
        return "integer", int(data[len("dword:"):].strip(), 16)

    m = re.match(r"^hex(?:\(([0-9a-fA-F]+)\))?:(.*)$", data, re.DOTALL)
    if m:
        subtype = m.group(1)
        raw = _hex_bytes(m.group(2))
        if subtype is None or subtype == "":          # hex: -> REG_BINARY
            return "binary", raw
        subtype = int(subtype, 16)
        if subtype == 2:                                # hex(2): -> REG_EXPAND_SZ
            return "expandable", _decode_utf16(raw)
        if subtype == 7:                                # hex(7): -> REG_MULTI_SZ
            return "multiString", _decode_multi_sz(raw)
        # hex(0)=REG_NONE, hex(b)=REG_QWORD, and anything else -> keep raw bytes.
        return "binary", raw

    # Unrecognised encoding: treat verbatim as a string so nothing is silently lost.
    return "string", data


def _hex_bytes(text):
    """'50,00,00' (possibly with backslash/newline continuations) -> bytes."""
    cleaned = re.sub(r"[\\\s]", "", text)
    cleaned = cleaned.replace(",", "")
    if cleaned == "":
        return b""
    try:
        return binascii.unhexlify(cleaned)
    except (binascii.Error, ValueError) as exc:
        raise ConversionError("bad hex data %r: %s" % (text, exc))


def _decode_utf16(raw):
    s = raw.decode("utf-16-le", errors="replace")
    return s.rstrip("\x00")


def _decode_multi_sz(raw):
    s = raw.decode("utf-16-le", errors="replace").rstrip("\x00")
    if s == "":
        return []
    return s.split("\x00")


_LINE_RE = re.compile(r"^(Registry|File|Directory)=(\+?)(.*)$")
_VAL_RE = re.compile(r'^"([^"]*)","([^"]*)"=(.*)$', re.DOTALL)
_KEY_RE = re.compile(r'^"([^"]*)"$')
_PATH_RE = re.compile(r'^"(.*)"$')


def parse_unl(text, direction="install"):
    """Yield Change objects from UNL text for the requested direction."""
    changes = []
    # Join .reg-style backslash continuations onto the logical line first.
    logical = _join_continuations(text.splitlines())
    for raw in logical:
        line = raw.strip()
        if not line:
            continue
        is_add = line.startswith(";")
        if is_add:
            line = line[1:].strip()
        # For 'install' we want added/changed items (the commented ';' lines).
        # For 'uninstall' we want the removals (uncommented lines).
        if direction == "install" and not is_add:
            continue
        if direction == "uninstall" and is_add:
            continue
        m = _LINE_RE.match(line)
        if not m:
            continue
        category, _plus, payload = m.group(1), m.group(2), m.group(3)
        try:
            change = _payload_to_change(category, payload)
        except ConversionError as exc:
            print("warning: skipping line (%s): %s" % (exc, raw), file=sys.stderr)
            continue
        if change is not None:
            changes.append(change)
    return changes


def _payload_to_change(category, payload):
    if category == "Registry":
        mval = _VAL_RE.match(payload)
        if mval:
            fullkey, name, data = mval.group(1), mval.group(2), mval.group(3)
            root, key = _split_root(fullkey)
            vtype, vdata = _parse_reg_data(data)
            return Change("regval", root=root, key=key, name=name,
                          vtype=vtype, vdata=vdata)
        mkey = _KEY_RE.match(payload)
        if mkey:
            root, key = _split_root(mkey.group(1))
            return Change("regkey", root=root, key=key)
        raise ConversionError("unparsable Registry payload")
    if category in ("File", "Directory"):
        mp = _PATH_RE.match(payload)
        if not mp:
            raise ConversionError("unparsable %s payload" % category)
        path = mp.group(1)
        return Change("file" if category == "File" else "dir", path=path)
    return None


def _join_continuations(lines):
    """Merge lines where a .reg hex payload was wrapped with a trailing '\\'."""
    out = []
    buf = None
    for line in lines:
        stripped = line.rstrip()
        if buf is not None:
            cont = line.strip()
            if cont.startswith(";"):
                cont = cont[1:].strip()
            buf += cont.rstrip("\\")
            if not stripped.endswith("\\"):
                out.append(buf)
                buf = None
            continue
        # A value line whose data was split ends with a backslash that is NOT an
        # escaped backslash inside a quoted string.
        if stripped.endswith("\\") and "=" in stripped and not stripped.endswith('\\\\'):
            buf = stripped.rstrip("\\")
        else:
            out.append(line)
    if buf is not None:
        out.append(buf)
    return out


# ---------------------------------------------------------------------------
# Directory tree (for staged files)
# ---------------------------------------------------------------------------

class DirNode:
    def __init__(self, node_id, name):
        self.id = node_id
        self.name = name
        self.children = {}          # name(lower) -> DirNode
        self.files = []             # list of (component_id, source_path, file_name)
        self.create = False         # emit a CreateFolder (captured empty dir)


class DirTree:
    def __init__(self, root_dir_id="INSTALLFOLDER"):
        self.root = DirNode(root_dir_id, None)
        self._n = 0

    def _new_id(self, hint):
        self._n += 1
        safe = re.sub(r"[^A-Za-z0-9_]", "_", hint) or "d"
        return "d%d_%s" % (self._n, safe[:32])

    def _descend(self, rel_parts):
        node = self.root
        for part in rel_parts:
            if part in ("", ".", ".."):
                continue
            key = part.lower()
            child = node.children.get(key)
            if child is None:
                child = DirNode(self._new_id(part), part)
                node.children[key] = child
            node = child
        return node

    def add_file(self, rel_parts, source_path):
        node = self._descend(rel_parts[:-1])
        self._n += 1
        comp_id = "c%d_%s" % (self._n, re.sub(r"[^A-Za-z0-9_]", "_", rel_parts[-1])[:24])
        node.files.append((comp_id, source_path, rel_parts[-1]))

    def add_dir(self, rel_parts):
        node = self._descend(rel_parts)
        node.create = True


def _relative_parts(path, strip_prefix):
    """Turn an absolute capture path into path parts under the install root."""
    norm = path.replace("/", "\\")
    if strip_prefix:
        sp = strip_prefix.replace("/", "\\").rstrip("\\")
        if norm.lower().startswith(sp.lower()):
            norm = norm[len(sp):]
    else:
        # Drop a leading drive letter ("C:\\...").
        norm = re.sub(r"^[A-Za-z]:\\?", "", norm)
    parts = [p for p in norm.split("\\") if p not in ("", ".")]
    return parts


# ---------------------------------------------------------------------------
# WiX emission
# ---------------------------------------------------------------------------

def _attr(value):
    return sax.quoteattr(str(value))


def build_wxs(changes, title, manufacturer, version, install_root, strip_prefix):
    upgrade_code = uuid.uuid5(_UPGRADE_NS, "regshot2msi:" + title)

    reg_components = []      # xml strings, one <Component> each
    tree = DirTree()

    # Keys that already receive a value create themselves, so a standalone
    # key-creation component would be redundant.
    keys_with_values = {
        (ch.root, ch.key.rstrip("\\").lower())
        for ch in changes if ch.kind == "regval"
    }

    reg_n = 0
    for ch in changes:
        if ch.kind == "regkey":
            if (ch.root, ch.key.rstrip("\\").lower()) in keys_with_values:
                continue
            reg_n += 1
            reg_components.append(_regkey_component(ch, "reg%d" % reg_n))
        elif ch.kind == "regval":
            reg_n += 1
            reg_components.append(_regval_component(ch, "reg%d" % reg_n))
        elif ch.kind == "file":
            parts = _relative_parts(ch.path, strip_prefix)
            if parts:
                tree.add_file(parts, ch.path)
        elif ch.kind == "dir":
            parts = _relative_parts(ch.path, strip_prefix)
            if parts:
                tree.add_dir(parts)

    # Nested <Directory> declarations for staged subfolders (child ids only;
    # INSTALLFOLDER itself is declared in the StandardDirectory below).
    dir_tree_lines = _emit_directory_tree(tree.root, indent="        ")
    # Flat <Component> list (each carries a Directory= reference).
    file_component_lines = _emit_dir_components(tree.root, indent="      ")

    lines = []
    lines.append('<?xml version="1.0" encoding="utf-8"?>')
    lines.append('<!-- Generated by regshot2msi from a Regshot Advanced UNL capture. -->')
    lines.append('<Wix xmlns="http://wixtoolset.org/schemas/v4/wxs">')
    lines.append('  <Package Name=%s Manufacturer=%s Version=%s UpgradeCode="{%s}" Compressed="yes" Scope="perMachine">'
                 % (_attr(title), _attr(manufacturer), _attr(version), str(upgrade_code).upper()))
    lines.append('    <MajorUpgrade DowngradeErrorMessage="A newer version is already installed." />')
    lines.append('    <MediaTemplate EmbedCab="yes" />')
    lines.append('')
    lines.append('    <StandardDirectory Id=%s>' % _attr(install_root))
    if dir_tree_lines:
        lines.append('      <Directory Id="INSTALLFOLDER" Name=%s>' % _attr(title))
        lines.extend(dir_tree_lines)
        lines.append('      </Directory>')
    else:
        lines.append('      <Directory Id="INSTALLFOLDER" Name=%s />' % _attr(title))
    lines.append('    </StandardDirectory>')
    lines.append('')
    lines.append('    <Feature Id="Main" Title=%s Level="1">' % _attr(title))
    lines.append('      <ComponentGroupRef Id="RegistryChanges" />')
    lines.append('      <ComponentGroupRef Id="FileChanges" />')
    lines.append('    </Feature>')
    lines.append('  </Package>')
    lines.append('')

    # Registry component group.
    lines.append('  <Fragment>')
    lines.append('    <ComponentGroup Id="RegistryChanges" Directory="INSTALLFOLDER">')
    if reg_components:
        for comp in reg_components:
            lines.extend("      " + c for c in comp)
    else:
        lines.append('      <!-- no registry additions captured -->')
    lines.append('    </ComponentGroup>')
    lines.append('  </Fragment>')
    lines.append('')

    # File / directory component group (components reference the directory Ids
    # declared under INSTALLFOLDER above).
    lines.append('  <Fragment>')
    lines.append('    <ComponentGroup Id="FileChanges">')
    if file_component_lines:
        lines.extend(file_component_lines)
    else:
        lines.append('      <!-- no file additions captured -->')
    lines.append('    </ComponentGroup>')
    lines.append('  </Fragment>')
    lines.append('</Wix>')
    return "\n".join(lines) + "\n"


def _regkey_component(ch, comp_id):
    # A registry-only component still needs a registry keypath. Use the key's
    # (Default) value so no extra named value is left behind; writing an empty
    # default value is enough to force the key into existence.
    return [
        '<Component Id=%s>' % _attr(comp_id),
        '  <RegistryValue Root=%s Key=%s Type="string" Value="" KeyPath="yes" />'
        % (_attr(ch.root), _attr(ch.key)),
        '</Component>',
    ]


def _regval_component(ch, comp_id):
    out = ['<Component Id=%s>' % _attr(comp_id)]
    common = 'Root=%s Key=%s' % (_attr(ch.root), _attr(ch.key))
    if ch.name:
        common += ' Name=%s' % _attr(ch.name)
    if ch.vtype == "multiString":
        out.append('  <RegistryValue %s Type="multiString" KeyPath="yes">' % common)
        for item in ch.vdata:
            out.append('    <MultiStringValue>%s</MultiStringValue>' % sax.escape(item))
        out.append('  </RegistryValue>')
    else:
        if ch.vtype == "binary":
            value = binascii.hexlify(ch.vdata).decode("ascii")
        elif ch.vtype == "integer":
            value = str(ch.vdata)
        else:
            value = ch.vdata
        out.append('  <RegistryValue %s Type=%s Value=%s KeyPath="yes" />'
                   % (common, _attr(ch.vtype), _attr(value)))
    out.append('</Component>')
    return out


def _emit_dir_components(node, indent):
    lines = []
    # Components for files that live directly in this directory.
    for comp_id, source, fname in node.files:
        lines.append('%s<Component Id=%s Directory=%s>' % (indent, _attr(comp_id), _attr(node.id)))
        lines.append('%s  <File Source=%s Name=%s />' % (indent, _attr(source), _attr(fname)))
        lines.append('%s</Component>' % indent)
    if node.create and not node.files:
        lines.append('%s<Component Directory=%s>' % (indent, _attr(node.id)))
        lines.append('%s  <CreateFolder />' % indent)
        lines.append('%s</Component>' % indent)
    # Child directories need to exist in the directory tree; declare them and
    # recurse. Directories are declared as a nested <Directory> reference tree
    # under INSTALLFOLDER via the DirRef mechanism.
    for child in node.children.values():
        sub = _emit_dir_components(child, indent)
        lines.extend(sub)
    return lines


def _emit_directory_tree(node, indent):
    """Emit the <Directory> nesting so child directory Ids resolve."""
    lines = []
    for child in node.children.values():
        lines.append('%s<Directory Id=%s Name=%s>' % (indent, _attr(child.id), _attr(child.name)))
        lines.extend(_emit_directory_tree(child, indent + "  "))
        lines.append('%s</Directory>' % indent)
    return lines


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Convert a Regshot Advanced UNL capture to a WiX .wxs source.")
    ap.add_argument("input", help="UNL capture file produced by Regshot Advanced")
    ap.add_argument("-o", "--output", help="output .wxs path (default: <input>.wxs)")
    ap.add_argument("--title", help="product name (default: derived from input file name)")
    ap.add_argument("--manufacturer", default="Repackaged with regshot2msi",
                    help="manufacturer / company name")
    ap.add_argument("--version", default="1.0.0.0", help="product version (default 1.0.0.0)")
    ap.add_argument("--install-root", default="ProgramFiles64Folder",
                    help="MSI root directory for staged files "
                         "(e.g. ProgramFiles64Folder, ProgramFilesFolder)")
    ap.add_argument("--strip-prefix", default=None,
                    help="capture path prefix to strip before staging files, "
                         "e.g. \"C:\\Program Files\\MyApp\". "
                         "Default strips only the drive letter.")
    ap.add_argument("--direction", choices=["install", "uninstall"], default="install",
                    help="build an install (added items) or uninstall (removed items) package")
    ap.add_argument("--encoding", default=None,
                    help="input encoding (default: try utf-16, utf-8-sig, utf-8)")
    args = ap.parse_args(argv)

    text = _read_text(args.input, args.encoding)

    title = args.title or os.path.splitext(os.path.basename(args.input))[0] or "Captured Package"
    output = args.output or (os.path.splitext(args.input)[0] + ".wxs")

    changes = parse_unl(text, direction=args.direction)
    if not changes:
        print("warning: no %s changes found in %s" % (args.direction, args.input),
              file=sys.stderr)

    wxs = build_wxs(changes, title=title, manufacturer=args.manufacturer,
                    version=args.version, install_root=args.install_root,
                    strip_prefix=args.strip_prefix)

    with open(output, "w", encoding="utf-8") as fh:
        fh.write(wxs)

    n_reg = sum(1 for c in changes if c.kind in ("regkey", "regval"))
    n_file = sum(1 for c in changes if c.kind == "file")
    n_dir = sum(1 for c in changes if c.kind == "dir")
    print("wrote %s  (%d registry, %d file, %d directory entries)"
          % (output, n_reg, n_file, n_dir))
    print("next: wix build %s -o %s" % (output, os.path.splitext(output)[0] + ".msi"))
    return 0


def _read_text(path, encoding):
    with open(path, "rb") as fh:
        raw = fh.read()
    if encoding:
        return raw.decode(encoding)
    # Honour a byte-order mark first (Regshot can emit UTF-16LE on Windows).
    if raw[:2] == b"\xff\xfe":
        return raw[2:].decode("utf-16-le", errors="replace")
    if raw[:2] == b"\xfe\xff":
        return raw[2:].decode("utf-16-be", errors="replace")
    if raw[:3] == b"\xef\xbb\xbf":
        return raw[3:].decode("utf-8", errors="replace")
    # No BOM: UTF-16LE data has NUL bytes between ASCII chars; use that as a hint.
    if b"\x00" in raw[:256]:
        try:
            return raw.decode("utf-16-le")
        except (UnicodeDecodeError, UnicodeError):
            pass
    for enc in ("utf-8", "latin-1"):
        try:
            return raw.decode(enc)
        except (UnicodeDecodeError, UnicodeError):
            continue
    return raw.decode("latin-1", errors="replace")


if __name__ == "__main__":
    sys.exit(main())
