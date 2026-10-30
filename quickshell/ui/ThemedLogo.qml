import QtQuick
import Quickshell.Io

Image {
    id: logo
    // Tint the SVG source itself. No offscreen layers, masks or thresholded edges.
    property url artwork
    property color color: Tok.accent
    width: 24; height: 24
    smooth: true; mipmap: true; antialiasing: true
    fillMode: Image.PreserveAspectFit
    sourceSize.width: Math.max(96, Math.ceil(width * 4))
    sourceSize.height: Math.max(96, Math.ceil(height * 4))
    FileView {
        id: vector
        path: decodeURIComponent(logo.artwork.toString().replace(/^file:\/\//, ""))
        blockLoading: true
    }
    source: {
        if (!artwork.toString().length) return "";
        var svg = vector.text();
        if (!svg) return "";
        var ink = logo.color.toString();
        svg = svg.replace(/#[0-9a-fA-F]{3,8}\b/g, ink)
                 .replace(/(["'])white\1/g, '"' + ink + '"')
                 .replace(/(["'])black\1/g, '"' + ink + '"')
                 .replace(/<svg\b/, '<svg fill="' + ink + '"');
        return "data:image/svg+xml," + encodeURIComponent(svg);
    }
}
