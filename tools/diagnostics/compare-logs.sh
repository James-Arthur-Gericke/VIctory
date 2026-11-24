#!/bin/sh
# Compare sampled VIctory frame summaries (UTF-8 logs). No game data required.
set -eu
if [ "$#" -ne 6 ]; then
    echo 'usage: sh compare-logs.sh BASE CAND BASE_START BASE_END CAND_START CAND_END' >&2
    exit 2
fi
for n in "$3" "$4" "$5" "$6"; do
    case "$n" in ''|*[!0-9]*) echo 'sample indices must be positive integers' >&2; exit 2;; esac
    [ "$n" -gt 0 ] || exit 2
done
[ "$3" -le "$4" ] && [ "$5" -le "$6" ] || exit 2
# Prefix relative file names to keep awk from interpreting them as assignments/options.
case "$1" in /*) base=$1;; *) base=./$1;; esac
case "$2" in /*) cand=$2;; *) cand=./$2;; esac
LC_ALL=C awk -v bs="$3" -v be="$4" -v cs="$5" -v ce="$6" '
function safe(s,    parts, fields, n, i) {
    s=tolower(s)
    if (s=="being made" || s=="no pipeline set") return s
    if (s ~ /^refused /) return "host pipeline refused (details omitted)"
    if (s ~ /^skipped shader [0-9a-f]+$/ && length(s)==31) return s
    n=split(s,parts,/ [+] /)
    for (i=1;i<=n;i++) {
        if (split(parts[i],fields," ")!=2 || fields[1] !~ /^(vertex|pixel|compute|mesh|geometry|hull|domain|amplification|task|vs|ps|cs|ms|gs|hs|ds|as)$/ || fields[2] !~ /^[0-9a-f]+$/ || length(fields[2])!=16)
            return "other (details omitted)"
    }
    return s
}
function metric(line, suffix,    s) {
    s=line; sub(suffix ".*$","",s); sub(/^.*[^0-9.]/,"",s); return s+0
}
BEGIN {
    lo[1]=bs; hi[1]=be; lo[2]=cs; hi[2]=ce
    names[1]="fps"; names[2]="ms/frame"; names[3]="draws/frame"; names[4]="dropped/frame"; names[5]="pipelines being made"; names[6]="indirect/frame"
    esc=sprintf("%c",27)
}
{
    if (side!=previous) { active=0; previous=side }
    line=$0; gsub(esc "\\[[0-?]*[ -/]*[@-~]","",line); sub(/\r$/,"",line)
    if (line ~ /[0-9.]+ fps, [0-9.]+ ms\/frame .* draws\/frame, dropped [0-9.]+ without a host pipeline \([0-9]+ being made\) and [0-9.]+ indirect/) {
        count[side]++; active=(count[side]>=lo[side] && count[side]<=hi[side]); if (!active) next
        selected[side]++
        sum[side,1]+=metric(line," fps,"); sum[side,2]+=metric(line," ms/frame")
        sum[side,3]+=metric(line," draws/frame,"); sum[side,4]+=metric(line," without a host pipeline")
        sum[side,5]+=metric(line," being made"); sum[side,6]+=metric(line," indirect")
        if (match(line, /sample_frames=[1-9][0-9]*/)) {
            w=substr(line,RSTART+14,RLENGTH-14)+0
            weights[side]+=w; weighted_samples[side]++
            weighted[side,2]+=w*metric(line," ms/frame")
            weighted[side,3]+=w*metric(line," draws/frame,")
            weighted[side,4]+=w*metric(line," without a host pipeline")
            weighted[side,6]+=w*metric(line," indirect")
        }
        next
    }
    if (active && line ~ /dropped [0-9.]+\/frame without a host pipeline: /) {
        v=metric(line,"/frame without a host pipeline:"); sub(/^.*\/frame without a host pipeline: /,"",line)
        label=safe(line); idx=count[side]; key=side SUBSEP idx SUBSEP label
        if (!(key in seen)) { seen[key]=1; listed[side,label]++ }
        totals[side,label]+=v
    }
}
END {
    if (selected[1]!=be-bs+1 || selected[2]!=ce-cs+1) {
        print "invalid window or missing recognized UTF-8 summaries" > "/dev/stderr"; exit 2
    }
    use_weights=(weighted_samples[1]==selected[1] && weighted_samples[2]==selected[2])
    if (use_weights) print "Frame-weighted estimates over reported samples; pending pipelines and reason details remain sample means."
    else print "Sample means (not whole-run frame means); frame counts missing in at least one window."
    print "Missing details are not zero."
    printf "%-24s %12s %12s %12s\n","metric","baseline","candidate","delta"
    for(i=1;i<=6;i++) {
        a=sum[1,i]/selected[1]; b=sum[2,i]/selected[2]
        if (use_weights && i==1 && weighted[1,2]>0 && weighted[2,2]>0) {
            a=1000*weights[1]/weighted[1,2]; b=1000*weights[2]/weighted[2,2]
        } else if (use_weights && i!=1 && i!=5) {
            a=weighted[1,i]/weights[1]; b=weighted[2,i]/weights[2]
        }
        printf "%-24s %12.3f %12.3f %+12.3f\n",names[i],a,b,b-a
    }
    for (key in listed) {
        split(key,p,SUBSEP); s=p[1]; label=p[2]
        printf "%s: %s; mean when listed %.3f (%d/%d samples)\n",(s==1?"baseline":"candidate"),label,totals[key]/listed[key],listed[key],selected[s]
    }
    print "Match scene, hardware, driver, cache and settings. Top-40 detail cap; joint shader reasons are not independent."
}' side=1 "$base" side=2 "$cand"
