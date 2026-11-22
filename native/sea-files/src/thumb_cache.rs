//! On-disk thumbnails in the freedesktop cache layout (~/.cache/thumbnails/normal/XX/HASH.png).
use crate::preview::Pixels;
use gtk::{gio, glib};
use gio::prelude::FileExt;
use std::fs;
use std::path::{Path, PathBuf};

fn uri_of(path: &Path) -> String {
    gio::File::for_path(path).uri().to_string()
}

fn cache_file(path: &Path) -> PathBuf {
    let uri = uri_of(path);
    let hash = format!("{:x}", md5::compute(uri.as_bytes()));
    let sub = &hash[..2];
    glib::user_cache_dir()
        .join("thumbnails/normal")
        .join(sub)
        .join(format!("{hash}.png"))
}

pub fn load(path: &Path) -> Option<Pixels> {
    let cache = cache_file(path);
    let src = fs::metadata(path).ok()?;
    let cached = fs::metadata(&cache).ok()?;
    use std::os::unix::fs::MetadataExt;
    if src.mtime() > cached.mtime() {
        return None;
    }
    let img = image::open(&cache).ok()?;
    let rgba = img.into_rgba8();
    let (width, height) = rgba.dimensions();
    Some(Pixels {
        width,
        height,
        rgba: rgba.into_raw(),
    })
}

pub fn save(path: &Path, pixels: &Pixels) {
    let cache = cache_file(path);
    if let Some(dir) = cache.parent() {
        let _ = fs::create_dir_all(dir);
    }
    if let Some(img) = image::RgbaImage::from_raw(pixels.width, pixels.height, pixels.rgba.clone()) {
        let tmp = cache.with_extension("png.tmp");
        if image::DynamicImage::ImageRgba8(img).save(&tmp).is_ok() {
            let _ = fs::rename(tmp, cache);
        }
    }
}
