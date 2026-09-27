#!/usr/bin/env bash
# Build and run the tiecook2 unit tests. Invoked by `make test`.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
build="$here/.build"
mkdir -p "$build"

fail=0
for src in "$here"/*_test.pas; do
    name="$(basename "$src" .pas)"
    echo "== building $name"
    fpc -Mobjfpc -Sh -vw -Fu"$root" -FU"$build" -o"$build/$name" "$src" >/dev/null
    echo "== running $name"
    if ! "$build/$name"; then
        fail=1
    fi
done

# CLI-level check: importing the same source twice must overwrite, not duplicate.
echo "== cli: re-import dedupe"
fpc -Mobjfpc -Sh -vw -FU"$build" -o"$build/tiecook2" "$root/tiecook2.pas" >/dev/null
mmf="$build/dedupe.mmf"
printf 'MMMMM----- Recipe via Meal-Master (tm) v8.06\r\n\r\n      Title: Test Soup\r\n Categories: Soup\r\n      Yield: 2 Servings\r\n\r\n   1.00 c  Water\r\n\r\n  Boil it.\r\nMMMMM\r\n' > "$mmf"
lib="$build/lib"; rm -rf "$lib"
"$build/tiecook2" import mealmaster --out "$lib" "$mmf" >/dev/null
n1=$(ls "$lib" | wc -l)
"$build/tiecook2" import mealmaster --out "$lib" "$mmf" >/dev/null
n2=$(ls "$lib" | wc -l)
if [ "$n1" = "1" ] && [ "$n2" = "1" ]; then
    echo "   dedupe OK (1 file after two imports)"
else
    echo "FAIL: re-import duplicated ($n1 file(s), then $n2)"
    fail=1
fi

exit $fail
