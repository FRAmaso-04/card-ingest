# Card Ingest - example settings
# Copy what you need into ~/.card_ingest/config.sh
# (install.sh already writes SSD_ROOT for you).

# Folder where projects are created (required)
SSD_ROOT="/Volumes/MySSD/Projects"

# Extensions recognised for each type
VIDEO_EXTENSIONS=(mp4 mov mxf braw r3d avi mts m2ts)
JPG_EXTENSIONS=(jpg jpeg heic png tif tiff)
RAW_EXTENSIONS=(cr2 cr3 nef arw dng raf orf rw2 raw)

# 1 = skip low-res proxy clips (e.g. C0001S03.MP4), 0 = copy them too
SKIP_VIDEO_PROXIES=1

# How long the gallery waits for your choice, in seconds
GALLERY_TIMEOUT_SECS=1200

# Local port for the gallery (change it if 8734 is busy)
GALLERY_PORT=8734

# Thumbnail size in pixels
GALLERY_THUMB_SIZE=320

# Rebuild the index of files already on the destination every N seconds
DEST_INDEX_MAX_AGE=21600
