#!/bin/sh
# Short "Vendor Model (Nth Gen)" CPU label for the fastfetch splash, read from
# lscpu on every run rather than hardcoded. Falls back to the untouched model
# name for CPUs that don't match Intel's "Nth Gen ... i5-xxxx" shape.

raw=$(LC_ALL=C lscpu | sed -n -E 's/^Model name:[[:space:]]*//p')

clean=$(printf '%s' "$raw" | sed -E '
    s/\(R\)//g
    s/\(TM\)//g
    s/ @ [0-9.]+GHz//
    s/ CPU / /g
    s/([0-9]+(st|nd|rd|th) Gen) (.*)/\3 (\1)/
    s/ Core / /
    s/ with .*Graphics.*$//
    s/[[:space:]]+/ /g
    s/^ //
    s/ $//
')

printf '%s' "${clean:-$raw}"
