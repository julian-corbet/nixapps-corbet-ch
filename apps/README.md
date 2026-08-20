# Recipes

**This directory is empty.** Every recipe was handed to the repository that owns
the application it described.

That is the finished state, not an unfinished one. An application is declared by
the repository whose subject it is — a wiki by the office repository, a notebook
by the notes one, an archive by the vault — and a second description here was a
duplicate nobody read and nothing rendered.

The mechanism is unchanged and still the point: one directory per recipe under
`apps/<category>/<app>/`, and that path is also the option path, so a recipe at
`apps/media/castopod/` would declare `nixapps.media.castopod` and set its delivery
project to `media` (CONTRACT.md R4). There is no central list of categories, here
or anywhere — the flake discovers them by reading the directory, which is why
adding one means adding a directory and why removing them all left nothing to
update but this file.

## Where each one went

| Owner | Applications |
|---|---|
| nixoffice | bookstack, overleaf, paperless, papra, calcom, leantime, planka, vikunja, collabora, eurooffice, directus |
| nixhome | grocy, homebox, donetick, assets (catalogued as `dumbassets`) |
| nixnotes | linkwarden, memos, quickchart, silverbullet |
| nixshare | pingvin, versitygw, syncthing |
| nixcloud | opencloud, rclone, nextcloud |
| nixvault | archivebox, tubearchivist |
| nixrecord | castopod, ontime |
| nixmsg | mattermost, tuwunel |
| nixdev | bytestash, cyberchef |
| nixdb | chartdb, whodb |
| nixcreative | comfyui, tts |
| nixk3s | homarr — the portal, which is the platform's own face rather than an app |

## What the recipes were, and what survived them

Their value was never the Nix. It was knowing that this application serves HTTP on
8080 with a web server already in the image; that it migrates its own database on
boot so a readiness probe has to be patient; that its documented Redis dependency
is only a cache; that it writes exactly one directory and everything else is in
the database. That knowledge is expensive to acquire and cheap to copy, and it is
what moved.

What survived unchanged is [CONTRACT.md](../CONTRACT.md): twelve rules stating
what a recipe is and where the line between knowledge and values falls. Those
rules now govern a dozen catalogues in a dozen repositories instead of one
directory here, which is a wider reach than they ever had from inside it.
