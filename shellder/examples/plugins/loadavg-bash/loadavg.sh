#!/usr/bin/env bash
# Plugin de exemplo do Shellder em Bash: linhas que não são JSON viram o texto.
while true; do
    read -r one _ < /proc/loadavg
    echo "$one"
    sleep 5
done
