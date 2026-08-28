#!/usr/bin/env python3
'''Golden-file self-test for compile-user-rules.py.

Compiles the checked-in fixture rule set against a fixed fake folder list
and asserts the output is byte-for-byte identical to the checked-in golden
file. Runs in the Docker build (a compiler regression fails the image
build) and at container start-up via prepare-sendmail.sh (a failing
self-test keeps /run/sendmail-ready unwritten, so the task never accepts
mail with a regressed compiler and ECS replaces it).

Paths are env-overridable so the repo unit tests can exercise the same
assertion against the working tree.
'''
import importlib.util
import os
import sys

COMPILER = os.environ.get('SELFTEST_COMPILER',
                          '/usr/local/bin/compile-user-rules.py')
DATA_DIR = os.environ.get('SELFTEST_DATA_DIR',
                          '/usr/local/share/cabal/compile-user-rules')

# Must match the folder set the golden file was generated against.
FIXTURE_FOLDERS = {'', '.Receipts', '.Archive', '.Work.Clients', '.Trash',
                   '.My Stuff', '.Newsletters'}
# And the enabled palette slots (rules-composition plan, decision 6).
FIXTURE_PALETTE = frozenset({'cabal-flag-01', 'cabal-flag-02',
                             'cabal-flag-07'})


def main():
    '''Returns 0 on byte-identical output, 1 (with a diff hint) otherwise.'''
    spec = importlib.util.spec_from_file_location('compile_user_rules', COMPILER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    import json  # pylint: disable=import-outside-toplevel
    with open(os.path.join(DATA_DIR, 'fixture-rules.json'), encoding='utf-8') as f:
        rules = json.load(f)
    with open(os.path.join(DATA_DIR, 'golden.rc'), encoding='utf-8') as f:
        golden = f.read()

    content, compiled, _skips = module.compile_ruleset(
        'fixtureuser', rules, lambda d: d in FIXTURE_FOLDERS,
        FIXTURE_PALETTE)
    if not content.endswith('\n'):
        content += '\n'
    if content != golden:
        print('[compile-user-rules-selftest] FAIL: output differs from golden')
        got = content.splitlines()
        want = golden.splitlines()
        for i, (g, w) in enumerate(zip(got, want)):
            if g != w:
                print(f'  first diff at line {i + 1}:')
                print(f'    got:  {g!r}')
                print(f'    want: {w!r}')
                break
        else:
            print(f'  length differs: got {len(got)} lines, want {len(want)}')
        return 1
    print(f'[compile-user-rules-selftest] OK ({compiled} rules, '
          f'{len(golden)} bytes)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
