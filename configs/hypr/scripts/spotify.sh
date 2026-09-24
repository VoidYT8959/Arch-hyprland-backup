#!/bin/bash

spotify &

while ! hyprctl clients | grep -q 'class: Spotify'; do
    sleep 0.2
done

hyprctl dispatch movetoworkspace 2,class:^(Spotify)$
