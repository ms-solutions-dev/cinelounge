import Core
import Foundation

// The handshake before playback: `POST /Items/{id}/PlaybackInfo`.
//
// **Without it the server clears playback away from under us.** It keeps every
// encoding under a session ID that IT assigns. Whoever invents their own — as happened
// here before, with a fresh UUID on every address build — reports progress for a
// session the server does not know. After about ten seconds it considers the encoding
// orphaned, ends it, and **deletes the data already delivered**. The player then runs
// into a 404, and on the TV that looks like "video stuck".

/// What the server has assigned for a playback.
///
/// Both identifiers must be carried along **everywhere** from here on: in the playback
/// address, in every position report, and when clearing the encoding away. A report
/// without them hangs on nothing at the server.
public struct PlaybackSession: Sendable, Equatable {

    /// The title the session applies to — so a report for a different title does not
    /// accidentally carry the foreign session.
    public let itemID: String
    public let playSessionID: String
    public let mediaSourceID: String

    public init(itemID: String, playSessionID: String, mediaSourceID: String) {
        self.itemID = itemID
        self.playSessionID = playSessionID
        self.mediaSourceID = mediaSourceID
    }
}

/// The shapes of the handshake, deliberately kept slim.
///
/// **Under their own name, because the server package occupies the same terms:**
/// `PlaybackInfoResponse` and `DeviceProfile` already exist in `JellyfinAPI`, and naming
/// them the same here would force every test file with both imports into a naming
/// conflict. Exactly two values are needed from the response anyway — session ID and
/// media source; everything else stays unread.
enum PlaybackHandshake {

    /// The body of the request: a simple device profile.
    ///
    /// It tells the server what this device can play directly and what it can accept as a
    /// repackaged stream. It needs nothing more — we build the address ourselves, the
    /// response only delivers the session.
    struct Body: Encodable {

        let deviceProfile: Profile

        enum CodingKeys: String, CodingKey {
            case deviceProfile = "DeviceProfile"
        }

        /// An Apple TV's profile, reduced to the essentials.
        ///
        /// Video: H.264 and HEVC — the device does both in hardware. Audio: AAC, AC-3,
        /// E-AC-3 — what it outputs; DTS and TrueHD are missing on purpose, and the server
        /// converts them. As repackaging target HLS with MP4 segments — the same way the
        /// playback address demands; a profile that promised something else would let the server
        /// decide differently for display than for delivery.
        /// - Parameter isNative: Whether **Apple's** engine will play.
        ///
        ///   **The profile must say what the engine that actually plays can do**
        ///   (schedule P11, after the format research of 2026-08-08). Here stood a profile
        ///   for both engines together — MKV as direct playback, although Apple's
        ///   engine can never open it. The server took the promise at its word and
        ///   delivered unchanged; for VLC that is correct, for the system player
        ///   a black picture without an error message. Who plays is long settled at the
        ///   handshake — so what this one can do is what gets asked.
        /// **Without a choice since there is only one engine** (AP8,
        /// added 2026-09-02). The `isNative` switch stood here with the default
        /// `false`, and the one call site in the app computed it from
        /// `engine == .native` — so, since the VLC removal, always `true`.
        /// The default thus described a device that does not exist: one that
        /// plays MKV unchanged. Whoever used it by accident
        /// promised the server exactly that.
        static func standard() -> Body {
            Body(
                deviceProfile: Profile(
                    name: "CineLounge",
                    directPlayProfiles: [
                        PlayProfile(
                            // Without MKV when Apple's engine plays: it cannot do the container, no matter which
                            // codec is inside.
                            container: "mp4,m4v,mov",
                            type: "Video",
                            // Asked instead of assumed: the Apple TV 4K (3rd gen.) cannot do AV1, a future model
                            // can (see ``DeviceCapabilities``).
                            videoCodec: DeviceCapabilities.videoCodecList,
                            audioCodec: "aac,ac3,eac3"
                        )
                    ],
                    codecProfiles: PlaybackHandshake.nativeCodecProfiles,
                    transcodingProfiles: [
                        ConversionProfile(
                            container: "mp4",
                            type: "Video",
                            videoCodec: DeviceCapabilities.videoCodecList,
                            audioCodec: "aac,ac3,eac3",
                            protocolName: "hls",
                            context: "Streaming"
                        )
                    ]
                )
            )
        }
    }

    struct Profile: Encodable {

        let name: String
        /// **Eight channels, explicitly.** Without a value Jellyfin assumes two and downmixes to
        /// stereo when converting — 5.1 silently becomes two-channel, and nobody sees why. Eight
        /// covers 7.1; no source in the catalog offers more.
        ///
        /// For **Atmos** this is also the condition: tvOS has no bitstream passthrough (verified,
        /// tvOS 26 changed nothing about that), the only way is E-AC3 with JOC — and that only
        /// works if the track is passed through unchanged **and** not limited to stereo.
        var maxAudioChannels: String = "8"
        let directPlayProfiles: [PlayProfile]
        var codecProfiles: [CodecProfile] = []
        let transcodingProfiles: [ConversionProfile]

        enum CodingKeys: String, CodingKey {
            case name = "Name"
            case maxAudioChannels = "MaxAudioChannels"
            case directPlayProfiles = "DirectPlayProfiles"
            case codecProfiles = "CodecProfiles"
            case transcodingProfiles = "TranscodingProfiles"
        }
    }

    /// What Apple's engine demands beyond the container.
    ///
    /// Every condition here is an error that would otherwise stay **silent**: the title
    /// starts, the picture stays black or stutters, and it looks like a broken file. With
    /// the conditions the server converts instead of delivering.
    struct CodecProfile: Encodable {

        let type: String
        let codec: String
        let conditions: [Condition]

        enum CodingKeys: String, CodingKey {
            case type = "Type"
            case codec = "Codec"
            case conditions = "Conditions"
        }

        struct Condition: Encodable {
            let condition: String
            let property: String
            let value: String
            /// `true` means: if the value is missing in the file, the condition counts as
            /// **violated**. Exactly right for the codec tag — a file without it is the case where
            /// things go wrong.
            let isRequired: Bool

            enum CodingKeys: String, CodingKey {
                case condition = "Condition"
                case property = "Property"
                case value = "Value"
                case isRequired = "IsRequired"
            }
        }
    }

    /// The native engine's conditions, from the research of 2026-08-08
    ///
    /// 1. **`hvc1` instead of `hev1`.** Apple's engine opens HEVC in MP4 only with this
    ///    tag; with `hev1` or `dvhe` it fails without a message. Swiftfin suffered from
    ///    exactly this for a long time.
    /// 2. **At most 60 frames per second.** Nothing in the catalog goes above that, and the
    ///    server would rather convert than let it stutter.
    /// 3. **No interlacing.** AVPlayer does not deinterlace — 1080i would stay as a comb
    ///    pattern.
    static let nativeCodecProfiles: [CodecProfile] = [
        CodecProfile(
            type: "Video",
            codec: "hevc",
            conditions: [
                // **Not as a requirement** — and this is a correction from the same day: set as a
                // requirement, a file without a reported tag counts as unsuitable, and Jellyfin by no
                // means always fills the field. The consequence was that the server suddenly converted
                // HEVC titles that had played directly before — long load times on opening, and the
                // Home images could not keep up because the line was tied up with converting (viewer
                // finding 2026-08-08, confirmed in the log: `ActiveEncodings` took eleven seconds).
                //
                // Without a requirement: if a **wrong** tag is there, it converts — exactly the case at
                // hand. If there is none, the previous behavior stays.
                .init(
                    condition: "EqualsAny", property: "VideoCodecTag",
                    value: "hvc1|dvh1", isRequired: false
                ),
                .init(
                    condition: "LessThanEqual", property: "VideoFramerate",
                    value: "60", isRequired: false
                ),
                .init(
                    condition: "Equals", property: "IsInterlaced",
                    value: "false", isRequired: false
                ),
            ]
        ),
        CodecProfile(
            type: "Video",
            codec: "h264",
            conditions: [
                .init(
                    condition: "LessThanEqual", property: "VideoFramerate",
                    value: "60", isRequired: false
                ),
                .init(
                    condition: "Equals", property: "IsInterlaced",
                    value: "false", isRequired: false
                ),
                // **At most eight bit** (device finding 2026-08-15, Woujeinspes Skutgro): no Apple device
                // decodes H.264 in ten bit (Hi10P), and the codec name alone does not reveal it.
                // Without this condition the server COPIES the video into the segmenting — "h264" is
                // in the codec list after all — and the engine stays black. With it, it converts, and
                // the title plays natively. Not as a requirement: a file without the value should not be
                // converted as a precaution — the same trade-off as with the codec tag above.
                .init(
                    condition: "LessThanEqual", property: "VideoBitDepth",
                    value: "8", isRequired: false
                ),
            ]
        ),
    ]

    struct PlayProfile: Encodable {

        let container: String
        let type: String
        let videoCodec: String
        let audioCodec: String

        enum CodingKeys: String, CodingKey {
            case container = "Container"
            case type = "Type"
            case videoCodec = "VideoCodec"
            case audioCodec = "AudioCodec"
        }
    }

    struct ConversionProfile: Encodable {

        let container: String
        let type: String
        let videoCodec: String
        let audioCodec: String
        /// `protocol` is a keyword in Swift — hence the detour via the name.
        let protocolName: String
        let context: String

        enum CodingKeys: String, CodingKey {
            case container = "Container"
            case type = "Type"
            case videoCodec = "VideoCodec"
            case audioCodec = "AudioCodec"
            case protocolName = "Protocol"
            case context = "Context"
        }
    }

    /// The response, boiled down to the two values we actually need.
    struct Reply: Decodable {

        struct Source: Decodable {
            let id: String?

            enum CodingKeys: String, CodingKey {
                case id = "Id"
            }
        }

        let mediaSources: [Source]
        let playSessionId: String?

        enum CodingKeys: String, CodingKey {
            case mediaSources = "MediaSources"
            case playSessionId = "PlaySessionId"
        }
    }
}
