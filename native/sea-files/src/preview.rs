//! Decoding pictures off the UI thread. Pure pixels go back to the window, and a picture nobody is
//! waiting for any more is dropped before the work is done, not after.
use gtk::{gdk, glib};
use std::path::Path;

pub struct Pixels {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
}

impl Pixels {
    pub fn texture(self) -> gdk::Texture {
        let stride = self.width as usize * 4;
        gdk::MemoryTexture::new(
            self.width as i32,
            self.height as i32,
            gdk::MemoryFormat::R8g8b8a8,
            &glib::Bytes::from_owned(self.rgba),
            stride,
        )
        .into()
    }
}

pub fn is_picture(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    [".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp"].iter().any(|e| lower.ends_with(e))
}

/// The picture fitted inside a square. `thumbnail` is a fast box filter: right for this job, since
/// nobody compares a preview to the original.
pub fn decode_fit(path: &Path, longest: u32) -> Option<Pixels> {
    let img = image::ImageReader::open(path).ok()?.with_guessed_format().ok()?.decode().ok()?;
    let img = if img.width() > longest || img.height() > longest { img.thumbnail(longest, longest) } else { img };
    let rgba = img.into_rgba8();
    let (width, height) = rgba.dimensions();
    Some(Pixels { width, height, rgba: rgba.into_raw() })
}

/// A square from the middle of the picture. Thumbnails fill their tile, so its rounded corners land
/// on the photo and not on the empty bands around one.
/// Grid icon at `side` pixels. Pictures, PDF first page, and video posters.
pub fn grid_thumb(path: &Path, name: &str, side: u32) -> Option<Pixels> {
    if is_picture(name) {
        return decode_square(path, side);
    }
    if ext_of(name) == "pdf" {
        return pdf_page(path, 1, side);
    }
    if is_video(name) {
        let size = side.to_string();
        let args: [&std::ffi::OsStr; 9] = [
            "ffmpegthumbnailer".as_ref(),
            "-i".as_ref(),
            path.as_os_str(),
            "-o".as_ref(),
            "-".as_ref(),
            "-c".as_ref(),
            "png".as_ref(),
            "-s".as_ref(),
            size.as_ref(),
        ];
        return tool("8", &args).and_then(|b| from_png(&b, side));
    }
    None
}

pub fn decode_square(path: &Path, side: u32) -> Option<Pixels> {
    let img = image::ImageReader::open(path).ok()?.with_guessed_format().ok()?.decode().ok()?;
    let edge = img.width().min(img.height());
    let img = img.crop_imm((img.width() - edge) / 2, (img.height() - edge) / 2, edge, edge);
    let img = if edge > side { img.thumbnail(side, side) } else { img };
    let rgba = img.into_rgba8();
    let (width, height) = rgba.dimensions();
    Some(Pixels { width, height, rgba: rgba.into_raw() })
}

/// What a file turned out to be, ready to show. Built on a background thread.
pub enum Made {
    Picture { pixels: Pixels, width: u32, height: u32 },
    Texture(gdk::Texture),
    Text(String),
    Pdf { pixels: Pixels, pages: u32, aspect: f64 },
    Video { poster: Option<Pixels>, facts: Vec<(String, String)> },
    Audio { cover: Option<Pixels>, facts: Vec<(String, String)> },
    Listing { text: String, count: usize },
    Folder { count: usize, text: String },
    Nothing,
}

fn ext_of(name: &str) -> String {
    Path::new(name).extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default()
}

pub fn is_video(name: &str) -> bool {
    ["mp4", "mkv", "webm", "mov", "avi", "m4v", "wmv", "flv", "ts", "mpg", "mpeg", "ogv", "3gp"].contains(&ext_of(name).as_str())
}
pub fn is_audio(name: &str) -> bool {
    ["mp3", "flac", "ogg", "opus", "wav", "m4a", "aac", "wma", "aiff", "alac", "ape"].contains(&ext_of(name).as_str())
}
pub fn is_archive(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    [".zip", ".7z", ".rar", ".tar", ".tar.gz", ".tgz", ".tar.xz", ".txz", ".tar.bz2", ".tbz2", ".tar.zst", ".gz", ".xz", ".bz2", ".iso", ".jar"].iter().any(|e| lower.ends_with(e))
}
pub fn archive_stem(name: &str) -> String {
    let lower = name.to_ascii_lowercase();
    for e in [".tar.gz", ".tar.xz", ".tar.bz2", ".tar.zst", ".tgz", ".txz", ".tbz2", ".zip", ".7z", ".rar", ".tar", ".gz", ".xz", ".bz2", ".iso", ".jar"] {
        if lower.ends_with(e) {
            return name[..name.len() - e.len()].to_string();
        }
    }
    name.to_string()
}

/// A tool's stdout, or nothing. Under `timeout`, because a damaged file can make these hang and a
/// stuck thread would quietly use up the preview pool.
fn tool(limit: &str, args: &[&std::ffi::OsStr]) -> Option<Vec<u8>> {
    let out = std::process::Command::new("timeout").arg(limit).args(args).stdin(std::process::Stdio::null()).stderr(std::process::Stdio::null()).output().ok()?;
    (out.status.success() && !out.stdout.is_empty()).then_some(out.stdout)
}

fn from_png(bytes: &[u8], longest: u32) -> Option<Pixels> {
    let img = image::load_from_memory(bytes).ok()?;
    let img = if img.width() > longest || img.height() > longest { img.thumbnail(longest, longest) } else { img };
    let rgba = img.into_rgba8();
    let (width, height) = rgba.dimensions();
    Some(Pixels { width, height, rgba: rgba.into_raw() })
}

pub fn pdf_page(path: &Path, page: u32, longest: u32) -> Option<Pixels> {
    let (p, size) = (page.to_string(), longest.to_string());
    let args: [&std::ffi::OsStr; 10] = ["pdftoppm".as_ref(), "-f".as_ref(), p.as_ref(), "-l".as_ref(), p.as_ref(), "-png".as_ref(), "-singlefile".as_ref(), "-scale-to".as_ref(), size.as_ref(), path.as_os_str()];
    from_png(&tool("15", &args)?, longest)
}

/// A page at exactly this many pixels across. Drawing a larger render smaller is what made text
/// break up: GTK's scaling is quick, not careful, so the pixels have to be right from the start.
pub fn pdf_page_at_width(path: &Path, page: u32, width: u32) -> Option<Pixels> {
    let (p, w) = (page.to_string(), width.to_string());
    let args: [&std::ffi::OsStr; 12] = ["pdftoppm".as_ref(), "-f".as_ref(), p.as_ref(), "-l".as_ref(), p.as_ref(), "-png".as_ref(), "-singlefile".as_ref(), "-scale-to-x".as_ref(), w.as_ref(), "-scale-to-y".as_ref(), "-1".as_ref(), path.as_os_str()];
    from_png(&tool("20", &args)?, u32::MAX)
}

/// (pages, height / width of the first page).
fn pdf_info(path: &Path) -> (u32, f64) {
    let Some(out) = tool("5", &["pdfinfo".as_ref(), path.as_os_str()]) else { return (1, 1.414) };
    let text = String::from_utf8_lossy(&out);
    let pages = text.lines().find_map(|l| l.strip_prefix("Pages:").and_then(|v| v.trim().parse().ok())).unwrap_or(1);
    let aspect = text.lines().find_map(|l| l.strip_prefix("Page size:")).and_then(|v| {
        let mut nums = v.split_whitespace().filter_map(|n| n.parse::<f64>().ok());
        Some(nums.next()?).zip(nums.next()).map(|(w, h)| h / w)
    });
    (pages, aspect.filter(|a| a.is_finite() && *a > 0.0).unwrap_or(1.414))
}

fn clock(seconds: f64) -> String {
    let s = seconds.max(0.0) as u64;
    if s >= 3600 { format!("{}:{:02}:{:02}", s / 3600, s / 60 % 60, s % 60) } else { format!("{}:{:02}", s / 60, s % 60) }
}

fn media_facts(path: &Path) -> Vec<(String, String)> {
    let args: [&std::ffi::OsStr; 8] = ["ffprobe".as_ref(), "-v".as_ref(), "error".as_ref(), "-print_format".as_ref(), "json".as_ref(), "-show_format".as_ref(), "-show_streams".as_ref(), path.as_os_str()];
    let Some(out) = tool("6", &args) else { return Vec::new() };
    let Ok(j) = serde_json::from_slice::<serde_json::Value>(&out) else { return Vec::new() };
    let mut facts = Vec::new();
    let tags = &j["format"]["tags"];
    for (label, keys) in [("Title", ["title", "TITLE"]), ("Artist", ["artist", "ARTIST"]), ("Album", ["album", "ALBUM"])] {
        if let Some(v) = keys.iter().find_map(|k| tags[*k].as_str()) {
            facts.push((label.to_string(), v.to_string()));
        }
    }
    if let Some(d) = j["format"]["duration"].as_str().and_then(|d| d.parse::<f64>().ok()) {
        facts.push(("Length".to_string(), clock(d)));
    }
    for s in j["streams"].as_array().map(Vec::as_slice).unwrap_or(&[]) {
        match s["codec_type"].as_str() {
            Some("video") if s["disposition"]["attached_pic"].as_i64() != Some(1) => {
                if let (Some(w), Some(h)) = (s["width"].as_i64(), s["height"].as_i64()) {
                    facts.push(("Dimensions".to_string(), format!("{w} × {h}")));
                }
            }
            Some("audio") => {
                if let Some(rate) = s["sample_rate"].as_str().and_then(|r| r.parse::<f64>().ok()) {
                    facts.push(("Sample rate".to_string(), format!("{:.1} kHz", rate / 1000.0)));
                }
            }
            _ => {}
        }
    }
    facts
}

fn document_text(path: &Path, inner: &str) -> Option<String> {
    let xml = tool("5", &["bsdtar".as_ref(), "-xOf".as_ref(), path.as_os_str(), inner.as_ref()])?;
    let xml = String::from_utf8_lossy(&xml).replace("</w:p>", "\n").replace("</text:p>", "\n").replace("</text:h>", "\n");
    let mut out = String::with_capacity(xml.len() / 4);
    let mut in_tag = false;
    for c in xml.chars() {
        match c {
            '<' => in_tag = true,
            '>' => in_tag = false,
            _ if !in_tag => out.push(c),
            _ => {}
        }
        if out.len() > 24 * 1024 {
            break;
        }
    }
    Some(out.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&apos;", "'"))
}

/// Works out what to show for one file or folder. `longest` is the size it will be drawn at, so a
/// huge photo never costs more than the pane it lands in.
pub fn make(path: &Path, name: &str, is_dir: bool, longest: u32) -> Made {
    if is_dir {
        let Ok(items) = std::fs::read_dir(path) else { return Made::Nothing };
        let mut names: Vec<String> = items.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).filter(|n| !n.starts_with('.')).collect();
        names.sort_by(|a, b| crate::core::natural_cmp(a, b));
        let count = names.len();
        names.truncate(40);
        return Made::Folder { count, text: names.join("\n") };
    }
    let ext = ext_of(name);
    if is_picture(name) {
        let probe = image::ImageReader::open(path).ok().and_then(|r| r.with_guessed_format().ok()).and_then(|r| r.into_dimensions().ok());
        if let Some(pixels) = decode_fit(path, longest) {
            let (width, height) = probe.unwrap_or((pixels.width, pixels.height));
            return Made::Picture { pixels, width, height };
        }
    }
    if ["svg", "svgz", "heic", "heif", "avif", "tif", "tiff", "ico", "jxl"].contains(&ext.as_str()) {
        if let Ok(tex) = gdk::Texture::from_filename(path) {
            return Made::Texture(tex);
        }
    }
    if ext == "pdf" {
        if let Some(pixels) = pdf_page(path, 1, longest) {
            let (pages, aspect) = pdf_info(path);
            return Made::Pdf { pixels, pages, aspect };
        }
    }
    if is_video(name) {
        let size = longest.to_string();
        let args: [&std::ffi::OsStr; 9] = ["ffmpegthumbnailer".as_ref(), "-i".as_ref(), path.as_os_str(), "-o".as_ref(), "-".as_ref(), "-c".as_ref(), "png".as_ref(), "-s".as_ref(), size.as_ref()];
        return Made::Video { poster: tool("8", &args).and_then(|b| from_png(&b, longest)), facts: media_facts(path) };
    }
    if is_audio(name) {
        let args: [&std::ffi::OsStr; 12] = ["ffmpeg".as_ref(), "-v".as_ref(), "error".as_ref(), "-i".as_ref(), path.as_os_str(), "-an".as_ref(), "-frames:v".as_ref(), "1".as_ref(), "-f".as_ref(), "image2pipe".as_ref(), "-c:v".as_ref(), "png".as_ref()];
        let mut all: Vec<&std::ffi::OsStr> = args.to_vec();
        all.push("-".as_ref());
        return Made::Audio { cover: tool("6", &all).and_then(|b| from_png(&b, longest)), facts: media_facts(path) };
    }
    if ext == "docx" {
        if let Some(text) = document_text(path, "word/document.xml") {
            return Made::Text(text);
        }
    }
    if ["odt", "ods", "odp"].contains(&ext.as_str()) {
        if let Some(text) = document_text(path, "content.xml") {
            return Made::Text(text);
        }
    }
    if is_archive(name) {
        if let Some(out) = tool("6", &["bsdtar".as_ref(), "-tf".as_ref(), path.as_os_str()]) {
            let list = String::from_utf8_lossy(&out);
            let count = list.lines().count();
            return Made::Listing { text: list.lines().take(200).collect::<Vec<_>>().join("\n"), count };
        }
    }
    match text_head(path, 24 * 1024) {
        Some(text) => Made::Text(text),
        None => Made::Nothing,
    }
}

/// The start of a file as text, or None if it isn't text. Only ever reads a small piece, so a 40 GB
/// log costs the same as a short note.
pub fn text_head(path: &Path, limit: usize) -> Option<String> {
    use std::io::Read;
    let mut buf = vec![0u8; limit];
    let n = std::fs::File::open(path).ok()?.read(&mut buf).ok()?;
    buf.truncate(n);
    if n == 0 || buf.contains(&0) {
        return None;
    }
    match String::from_utf8(buf) {
        Ok(s) => Some(s),
        Err(e) if e.utf8_error().error_len().is_none() => {
            // The read stopped in the middle of a character, which is fine.
            let valid = e.utf8_error().valid_up_to();
            let mut b = e.into_bytes();
            b.truncate(valid);
            String::from_utf8(b).ok()
        }
        Err(_) => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn binary_is_not_text_and_a_cut_character_is_fine() {
        let d = std::env::temp_dir().join(format!("sea-files-prev-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        std::fs::write(d.join("bin"), [0u8, 1, 2]).unwrap();
        assert_eq!(text_head(&d.join("bin"), 64), None);
        std::fs::write(d.join("t"), "héllo").unwrap();
        assert_eq!(text_head(&d.join("t"), 2).as_deref(), Some("h"));
        assert_eq!(text_head(&d.join("t"), 64).as_deref(), Some("héllo"));
    }

    #[test]
    fn pictures_are_fitted_inside_the_limit() {
        let d = std::env::temp_dir().join(format!("sea-files-pic-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        let p = d.join("a.png");
        image::RgbaImage::new(400, 100).save(&p).unwrap();
        let out = decode_fit(&p, 200).unwrap();
        assert_eq!((out.width, out.height), (200, 50));
        assert_eq!(out.rgba.len(), 200 * 50 * 4);
        let square = decode_square(&p, 64).unwrap();
        assert_eq!((square.width, square.height), (64, 64));
        assert!(is_picture("X.JPG") && !is_picture("x.txt"));
        assert_eq!(archive_stem("a.b.tar.gz"), "a.b");
        assert!(is_archive("x.ZIP") && is_video("x.MKV") && is_audio("x.flac"));
    }
}
