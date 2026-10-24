#!/usr/bin/env bash
# Example Shellder plugin in Bash: lines that are not JSON become the text.
while true; do
    read -r one _ < /proc/loadavg
    echo "$one"
    sleep 5
done
