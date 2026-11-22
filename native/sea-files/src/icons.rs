//! File type icons and labels. MIME guess from the name alone often returns octet-stream;
//! extension fallbacks keep the grid and preview pane honest.
use gtk::{gio, glib::object::Cast};
use std::path::Path;

pub fn for_entry(name: &str, is_dir: bool) -> (gio::Icon, String) {
    if is_dir {
        return (gio::ThemedIcon::new("folder").upcast(), "Folder".to_string());
    }
    let ext = Path::new(name)
        .extension()
        .and_then(|x| x.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    if let Some((icon, kind)) = by_extension(&ext) {
        return (gio::ThemedIcon::new(icon).upcast(), kind.to_string());
    }
    let (ty, _) = gio::content_type_guess(Some(name), None::<&[u8]>);
    let desc = gio::content_type_get_description(&ty);
    if ty.is_empty() || ty == "application/octet-stream" {
        (
            gio::ThemedIcon::new("text-x-generic").upcast(),
            if desc.is_empty() { "File".into() } else { desc.to_string() },
        )
    } else {
        (gio::content_type_get_icon(&ty), desc.to_string())
    }
}

fn by_extension(ext: &str) -> Option<(&'static str, &'static str)> {
    Some(match ext {
        "pdf" => ("application-x-pdf", "PDF Document"),
        "doc" | "docx" | "odt" => ("x-office-document", "Document"),
        "ppt" | "pptx" | "odp" => ("x-office-document-presentation", "Presentation"),
        "xls" | "xlsx" | "ods" | "csv" => ("x-office-spreadsheet", "Spreadsheet"),
        "txt" | "md" | "markdown" | "rst" | "log" => ("text-x-generic", "Text"),
        "py" | "pyw" => ("text-x-python", "Python"),
        "js" | "mjs" | "ts" | "tsx" | "jsx" => ("text-x-script", "Script"),
        "json" | "yaml" | "yml" | "toml" | "xml" | "ini" | "cfg" | "conf" => ("text-x-generic", "Settings"),
        "zip" | "7z" | "rar" | "tar" | "gz" | "xz" | "bz2" | "zst" | "jar" => ("application-x-zip", "Archive"),
        "png" | "jpg" | "jpeg" | "gif" | "webp" | "bmp" | "svg" => ("image-x-generic", "Image"),
        "mp4" | "mkv" | "webm" | "mov" | "avi" => ("video-x-generic", "Video"),
        "mp3" | "flac" | "ogg" | "opus" | "wav" | "m4a" => ("audio-x-generic", "Audio"),
        "html" | "htm" => ("text-html", "HTML"),
        "sh" | "bash" => ("text-x-script", "Shell script"),
        "rs" | "c" | "cpp" | "h" | "go" | "java" => ("text-x-generic", "Source code"),
        _ => return None,
    })
}
