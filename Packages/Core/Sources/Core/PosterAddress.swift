import Foundation

/// The URL of a tile's poster — decided in **one** place.
///
/// **The occasion** (viewer finding 2026-08-22, "Lofriok. Griopial"): the series appeared in the
/// grid as an empty frame. On the media server it is fine — it has
/// no poster, only a backdrop image:
///
/// ```
/// Items/{id}/Images/Primary   → 404
/// Items/{id}/Images/Backdrop  → 200, 1280 × 720
/// ```
///
/// Nevertheless the poster URL was built: the call sites wrote
/// throughout `posterID ?? item.id` — and because ``ItemMapping`` sets `posterID` **only**
/// when the server carries a poster, this `?? item.id` was the
/// instruction to request an image that was already known to be missing. One
/// 404 per tile, and in the end a black rectangle.
///
/// Here is the order: poster, otherwise thumbnail, otherwise
/// backdrop. A 16:9 image in a 2:3 frame is cropped — but it shows
/// what it is about, and an empty frame does not do that.
///
/// **And otherwise `nil`.** Without any image there is no URL anymore, instead of one
/// that leads surely nowhere: the tile shows its placeholder immediately, without
/// the detour via a request that must fail.
public enum PosterAddress {

    public static func url(
        for item: MediaItem,
        from source: any ContentSource,
        width: Int
    ) -> URL? {
        let artwork = item.artwork

        if let poster = artwork.posterID {
            return source.imageURL(
                itemID: poster, kind: .primary, width: width, tag: artwork.posterTag)
        }
        if let thumb = artwork.thumbID {
            return source.imageURL(
                itemID: thumb, kind: .thumb, width: width, tag: artwork.thumbTag)
        }
        if let backdrop = artwork.backdropID {
            return source.imageURL(
                itemID: backdrop, kind: .backdrop, width: width, tag: artwork.backdropTag)
        }
        return nil
    }
}
