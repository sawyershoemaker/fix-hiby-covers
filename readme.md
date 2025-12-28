# fix_hiby_covers.sh

HiBy R3 Pro 2 refuses to display album art embedded as progressive JPEGs and Tidal downloads from TidaLuna's downloader plugin default to progressive encoding, so anything downloaded from there shows up as unknown!

This script converts covers back to baseline JPEGs and re-embeds them into the FLAC files automagically!

## basic overview

- Give it either a Windows path (`C:\Music`) or a WSL path (`/mnt/d/Music`) to the root of the songs that need conversion.
- It will go through every `.flac` and extrect the current cover with `ffmpeg`.
- Then it re-encodes progressive covers with ImageMagick (`convert`) to a baseline JPEG, strips metadata, caps size at 1000x1000, and writes it back with `metaflac`. I found any bigger than 1000x1000 it either had issues displaying or was not worth the space.
- It also runs work in parallel (`nproc` workers) to deal with large libraries efficiently.

## requirements

- You'll need WSL with `ffmpeg`, `flac`, `imagemagick`, and the typical shell utilities.
- It's setup to attempt `sudo apt install` for anything missing, so you'll need sudo rights the first time or preinstall the aforementioned packages before running and run w/o sudo.

## syntax

```bash
./fix_hiby_covers.sh "C:\Users\sawyershoemaker\Music"
 ```

 or

 ```bash
./fix_hiby_covers.sh /mnt/c/Music
```

Backup your files or atleast just the metadata if you're worried about file-loss or can't download them again. JIC!

## Notes

- Only FLACs
- Any FLACs with NO art will remain untouched.
