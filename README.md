# MEOW SPLIT

Splits a multichannel WAV into stereo WAVs from Finder: right-click a `.wav` > Open With > MEOW SPLIT.
A folder named after the file appears beside it with `name 1-2.wav`, `name 3-4.wav`, ... (bit depth,
sample rate and format kept bit-exact; RF64 written when an output passes 4 GB). Opening the app on its
own shows settings (odd last channel: mono / dual mono / skip, reveal in Finder, colours).

Build: `./build.sh` (into `build/`) or `./build.sh --install` (to /Applications, registered with Finder).
