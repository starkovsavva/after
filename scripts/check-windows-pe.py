#!/usr/bin/env python3
"""Check Windows x64 preview binaries without executing them.

Uses the PE/COFF layout documented by Microsoft:
https://learn.microsoft.com/en-us/windows/win32/debug/pe-format
A developer machine's installed VC runtimes must not hide a broken package.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import re
import struct


def inspect(path: Path) -> dict:
    data = path.read_bytes()
    def read(fmt, offset):
        size = struct.calcsize(fmt)
        if offset < 0 or offset + size > len(data):
            raise ValueError('Truncated PE structure')
        return struct.unpack_from(fmt, data, offset)
    if len(data) < 64 or data[:2] != b'MZ':
        raise ValueError('Expected a Windows PE executable')
    pe, = read('<I', 60)
    if data[pe:pe+4] != b'PE\0\0':
        raise ValueError('Invalid PE signature')
    machine, count = read('<HH', pe+4)
    optional_size, characteristics = read('<HH', pe+20)
    if machine != 0x8664 or not 0 < count <= 96:
        raise ValueError('Expected an AMD64/x64 executable')
    if not characteristics & 2 or characteristics & 0x2000:
        raise ValueError('Expected an executable image rather than a DLL')
    optional = pe + 24
    magic, = read('<H', optional)
    if magic != 0x20b or optional_size < 112:
        raise ValueError('Expected a PE32+ optional header')
    image_base, = read('<Q', optional+24)
    headers_size, = read('<I', optional+60)
    directories, = read('<I', optional+108)
    sections = []
    for i in range(count):
        at = optional + optional_size + i*40
        virtual_size, virtual, raw_size, raw = read('<IIII', at+8)
        sections.append((virtual, virtual_size, raw_size, raw))
    def offset(rva, size=1):
        if rva < headers_size and rva + size <= min(headers_size, len(data)):
            return rva
        for virtual, virtual_size, raw_size, raw in sections:
            delta = rva - virtual
            if 0 <= delta and delta + size <= raw_size and raw + delta + size <= len(data):
                return raw + delta
        raise ValueError('PE RVA has no complete file-backed section')
    def name(rva):
        at=offset(rva)
        end=data.find(b'\0',at,min(len(data),at+1024))
        if end < 0:
            raise ValueError('Unterminated PE DLL name')
        value=data[at:end].decode('ascii').lower()
        if not re.fullmatch(r'[a-z0-9_.-]+\.dll',value):
            raise ValueError('Invalid imported DLL name')
        return value
    imports=set()
    def directory(index):
        if directories <= index or optional_size < 112+(index+1)*8:
            return 0,0
        return read('<II',optional+112+index*8)
    rva,size=directory(1)
    if rva:
        if not 20 <= size <= 1024*1024:
            raise ValueError('Invalid PE import directory bounds')
        for step in range(0,size,20):
            item=read('<IIIII',offset(rva+step,20))
            if not any(item): break
            imports.add(name(item[3]))
        else:
            raise ValueError('Unterminated PE import table')
    rva,size=directory(13)
    if rva:
        if not 32 <= size <= 1024*1024:
            raise ValueError('Invalid delayed import directory bounds')
        for step in range(0,size,32):
            item=read('<IIIIIIII',offset(rva+step,32))
            if not any(item): break
            imports.add(name(item[1] if item[0]&1 else item[1]-image_base))
        else:
            raise ValueError('Unterminated delayed import table')
    external=[value for value in imports if re.match(r'(?:vcruntime|msvcp|msvcr|concrt)[0-9_]',value)
              or value.startswith(('libssl','libcrypto','sqlite3'))]
    if external:
        raise ValueError('Unbundled developer runtime dependency: '+', '.join(sorted(external)))
    return {'file':str(path),'machine':'AMD64','externalCRuntime':False,'imports':sorted(imports)}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binaries',type=Path,nargs='+')
    parser.add_argument('--output',type=Path)
    args=parser.parse_args()
    result=[inspect(path) for path in args.binaries]
    if args.output:
        args.output.parent.mkdir(parents=True,exist_ok=True)
        args.output.write_text(json.dumps(result,indent=2)+'\n')
    for item in result:
        print('PASS: x64 PE, no external VC/OpenSSL/SQLite runtime:',item['file'])


if __name__=='__main__': main()
