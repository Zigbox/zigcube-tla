#!/usr/bin/env bash
# Runs TLC on every config in configs/ and checks each against what the
# config says to expect (its second line: "\* EXPECT ok", "\* EXPECT invariant
# <name>" or "\* EXPECT temporal").  Exits non-zero on any other result.
#
#   ./run.sh                 every config but the slow ones
#   ./run.sh --slow          the slow ones too
#   ./run.sh base teeth-skew only these
#
# TLC's full output, with the counterexample traces, is left in out/.
set -euo pipefail
cd "$(dirname "$0")"

JAR_VERSION=v1.7.4
JAR_URL="https://github.com/tlaplus/tlaplus/releases/download/${JAR_VERSION}/tla2tools.jar"
JAR_SHA256=936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88
JAR=.tools/tla2tools.jar

command -v java >/dev/null || { echo "run.sh: java is not installed (any JDK or JRE, 11 or later)" >&2; exit 2; }
if [ ! -f "$JAR" ]; then
    mkdir -p .tools
    echo "run.sh: downloading tla2tools.jar ${JAR_VERSION}" >&2
    curl -fsSL --retry 3 -o "$JAR.part" "$JAR_URL"
    mv "$JAR.part" "$JAR"
fi
echo "${JAR_SHA256}  ${JAR}" | sha256sum -c --quiet - || {
    echo "run.sh: ${JAR} does not have the pinned SHA-256; delete it and run again" >&2
    exit 2
}

slow=0
names=()
for arg in "$@"; do
    case "$arg" in
        --slow) slow=1 ;;
        *) names+=("${arg%.cfg}") ;;
    esac
done
if [ ${#names[@]} -eq 0 ]; then
    for f in configs/*.cfg; do
        if [ "$slow" -eq 0 ] && grep -q '^\\\* SLOW' "$f"; then continue; fi
        names+=("$(basename "$f" .cfg)")
    done
fi

unset JAVA_TOOL_OPTIONS
mkdir -p out
failed=0
printf '| %-28s | %-32s | %-32s | %10s | %9s | %5s | %5s | %s |\n' \
    config expected result generated distinct depth time ""
printf '|%s|%s|%s|%s|%s|%s|%s|%s|\n' ------------------------------ ---------------------------------- \
    ---------------------------------- ------------ ----------- ------- ------- ------
for name in "${names[@]}"; do
    cfg="configs/${name}.cfg"
    [ -f "$cfg" ] || { echo "run.sh: no such config: $cfg" >&2; exit 2; }
    expected=$(sed -n '2s/^\\\* EXPECT //p' "$cfg")
    [ -n "$expected" ] || { echo "run.sh: $cfg: the second line must be '\\* EXPECT ...'" >&2; exit 2; }
    log="out/${name}.out"
    rm -rf "out/${name}.states"
    start=$SECONDS
    java -XX:+UseParallelGC -cp "$JAR" tlc2.TLC -workers auto -difftrace -nowarning \
        -metadir "out/${name}.states" -config "$cfg" Fencing.tla >"$log" 2>&1 || true
    elapsed=$((SECONDS - start))
    rm -rf "out/${name}.states"
    if grep -q 'Model checking completed. No error has been found.' "$log"; then
        result=ok
    elif grep -q '^Error: Invariant .* is violated' "$log"; then
        result="invariant $(sed -n 's/^Error: Invariant \(.*\) is violated.*/\1/p' "$log" | head -1)"
    elif grep -q '^Error: Temporal properties were violated' "$log"; then
        result=temporal
    else
        result="error (see $log)"
    fi
    generated=$(sed -n 's/^\([0-9]*\) states generated, \([0-9]*\) distinct states found.*/\1/p' "$log" | tail -1)
    distinct=$(sed -n 's/^\([0-9]*\) states generated, \([0-9]*\) distinct states found.*/\2/p' "$log" | tail -1)
    depth=$(sed -n 's/^The depth of the complete state graph search is \([0-9]*\).*/\1/p' "$log" | tail -1)
    verdict=pass
    if [ "$result" != "$expected" ]; then verdict=FAIL; failed=1; fi
    printf '| %-28s | %-32s | %-32s | %10s | %9s | %5s | %4ss | %s |\n' \
        "$name" "$expected" "$result" "${generated:--}" "${distinct:--}" "${depth:--}" "$elapsed" "$verdict"
done
if [ "$failed" -ne 0 ]; then
    echo "run.sh: at least one config did not give the expected result" >&2
    exit 1
fi
