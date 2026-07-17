#!/usr/bin/env python3
"""Golden-output fixtures for mayhem/test.sh section (B) — never runs the program under test.

classes_test.uhdm-dump.tmpl is the EXACT text `uhdm-dump <seed>` prints for
mayhem/uhdm-dump/testsuite/classes_test.uhdm (captured from upstream UHDM at the integrated
commit), with every symbol name of the encoded design replaced by a placeholder.

  expect  <tmpl> <path> <out.expected>
      Fill the template with the seed's ORIGINAL names -> the exact expected dump of the seed.

  variant <seed> <tmpl> <path> <out.uhdm> <out.expected>
      Write a copy of the seed whose symbol names are replaced by FRESH RANDOM names (a new set on
      every call), plus the exact dump expected for it. The seed is a packed capnproto message and
      each name lives in its symbol table as literal (non-zero) bytes, so swapping them for other
      non-zero letters of the same length keeps the packing tags and every pointer valid: the result
      is still a well-formed UHDM file describing the same design with different names. A program
      can only print the right names by actually restoring the file — a canned/hard-coded dump of the
      seed (e.g. a patch that makes util/uhdm-dump.cpp print the golden text and return 0) fails.
"""
import random
import string
import sys

ORIG = {
    'DESIGN': 'design1', 'MOD': 'M1', 'FILE': 'fake1.sv', 'BASE': 'Base', 'CHILD': 'Child',
    'P1': 'P1', 'F1': 'f1', 'F2': 'f2', 'F3': 'f3',
}


def fill(tmpl, names, path):
    out = tmpl.replace('@PATH@', path)
    for key, val in names.items():
        out = out.replace('@%s@' % key, val)
    assert '@' not in out.replace(path, ''), 'unfilled placeholder'
    return out


def fresh_names():
    rng = random.SystemRandom()
    taken = {'a', '@@BAD_SYMBOL@@'} | set(ORIG.values())
    names = {}
    for key, val in ORIG.items():
        n = len(val) - 3 if key == 'FILE' else len(val)
        while True:
            cand = rng.choice(string.ascii_letters) + ''.join(
                rng.choice(string.ascii_letters + string.digits) for _ in range(n - 1))
            if key == 'FILE':
                cand += '.sv'
            if cand not in taken:
                break
        taken.add(cand)
        names[key] = cand
    return names


def mutate(seed, nm):
    """Byte-level rename inside the packed symbol table. Each pattern includes its packing tag
    byte(s) and must occur exactly once, so nothing outside the symbol table is touched."""
    b = lambda s: s.encode()
    subs = [
        (b'\x7f' + b(ORIG['DESIGN']), b'\x7f' + b(nm['DESIGN'])),
        (b'\x03M1\xff', b'\x03' + b(nm['MOD']) + b'\xff'),
        (b'\xff' + b(ORIG['FILE']), b'\xff' + b(nm['FILE'])),
        (b'\x0fBase', b'\x0f' + b(nm['BASE'])),
        (b'\x03P1', b'\x03' + b(nm['P1'])),
        (b'\x03f1', b'\x03' + b(nm['F1'])),
        (b'\x03f2', b'\x03' + b(nm['F2'])),
        (b'\x1fChild', b'\x1f' + b(nm['CHILD'])),
        (b'\x03f3', b'\x03' + b(nm['F3'])),
        (b'\xffM1::Base', b'\xff' + b(nm['MOD']) + b'::' + b(nm['BASE'])),
        (b'\xffM1::Chil\x00\x01d',
         b'\xff' + b(nm['MOD']) + b'::' + b(nm['CHILD'][:4]) + b'\x00\x01' + b(nm['CHILD'][4])),
    ]
    for old, new in subs:
        assert len(old) == len(new), (old, new)
        assert seed.count(old) == 1, 'seed layout changed: %r occurs %d times' % (old, seed.count(old))
        seed = seed.replace(old, new)
    return seed


def main(argv):
    if len(argv) == 5 and argv[1] == 'expect':
        _, _, tmpl, path, out = argv
        open(out, 'w').write(fill(open(tmpl).read(), ORIG, path))
    elif len(argv) == 7 and argv[1] == 'variant':
        _, _, seed, tmpl, path, out_uhdm, out_exp = argv
        nm = fresh_names()
        open(out_uhdm, 'wb').write(mutate(open(seed, 'rb').read(), nm))
        open(out_exp, 'w').write(fill(open(tmpl).read(), nm, path))
        print(' '.join('%s=%s' % kv for kv in sorted(nm.items())))
    else:
        sys.stderr.write(__doc__)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
