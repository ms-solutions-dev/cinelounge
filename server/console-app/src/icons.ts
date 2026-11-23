// Extracted 1:1 from design/vorfuehrraum-mockup.src.html. Changed on the owner's
// word (09.11.2026): `konto` is a gear (the mockup's read as a sun) and `einlass`
// an open door (the ticket was hard to read) — both from Lucide (ISC licence).

export const LOGO = "<svg viewBox=\"0 0 24 24\" aria-hidden=\"true\"><defs><clipPath id=\"bag\"><path d=\"M7.6 6.4h8.8l-1.1 7.9H8.7z\"/></clipPath></defs><path d=\"M6.6 10.4h10.8v4.6H6.6z\" fill=\"#7E170F\"/><path d=\"M3.4 12.2a1.5 1.5 0 0 1 1.5-1.5h.8v6.1H3.4zM17.8 10.7h.8a1.5 1.5 0 0 1 1.5 1.5v4.6h-2.3z\" fill=\"#A81F16\"/><path d=\"M4.9 15.6h14.2v3a1.5 1.5 0 0 1-1.5 1.5H6.4a1.5 1.5 0 0 1-1.5-1.5z\" fill=\"#96190F\"/><path d=\"M7.6 6.4h8.8l-1.1 7.9H8.7z\" fill=\"#F7EBD6\"/><g clip-path=\"url(#bag)\" fill=\"#C4302B\"><rect x=\"8.4\" y=\"6.4\" width=\"1.5\" height=\"8\"/><rect x=\"11.3\" y=\"6.4\" width=\"1.5\" height=\"8\"/><rect x=\"14.2\" y=\"6.4\" width=\"1.5\" height=\"8\"/></g><g fill=\"#FFF8E9\"><circle cx=\"8.4\" cy=\"5.6\" r=\"1.7\"/><circle cx=\"12\" cy=\"4.5\" r=\"1.9\"/><circle cx=\"15.6\" cy=\"5.6\" r=\"1.7\"/><circle cx=\"10.2\" cy=\"3.9\" r=\"1.4\"/><circle cx=\"13.9\" cy=\"3.9\" r=\"1.4\"/></g></svg>";
export const VCHK = "<svg class=\"vchk\" viewBox=\"0 0 24 24\" aria-label=\"verifiziert\"><path d=\"M12 2l2.4 2.1 3.2-.3.9 3.1 2.8 1.6-1 3 1 3-2.8 1.6-.9 3.1-3.2-.3L12 22l-2.4-2.1-3.2.3-.9-3.1-2.8-1.6 1-3-1-3 2.8-1.6.9-3.1 3.2.3z\" fill=\"#3b82f6\"/><path d=\"M8.3 12.2l2.5 2.5 4.9-5\" stroke=\"#fff\" stroke-width=\"2\" fill=\"none\" stroke-linecap=\"round\"/></svg>";
export const TGI = "<svg viewBox=\"0 0 24 24\" aria-hidden=\"true\"><circle cx=\"12\" cy=\"12\" r=\"11\" fill=\"#2aabee\"/><path d=\"M5.5 11.8l11-4.3c.5-.2 1 .1.8.9l-1.9 8.9c-.1.6-.5.8-1 .5l-2.9-2.1-1.4 1.3c-.2.2-.3.3-.6.3l.2-2.9 5.3-4.8c.2-.2 0-.3-.3-.1l-6.6 4.1-2.8-.9c-.6-.2-.6-.6.2-.9z\" fill=\"#fff\"/></svg>";
export const ICONS: Record<string, string> = {
  "home": "<path d=\"M3 11l9-7 9 7\"/><path d=\"M5 10v10h14V10\"/><path d=\"M10 20v-6h4v6\"/>",
  "einlass": "<path d=\"M13 4h3a2 2 0 0 1 2 2v14\"/><path d=\"M2 20h3\"/><path d=\"M13 20h9\"/><path d=\"M10 12v.01\"/><path d=\"M13 4.562v16.157a1 1 0 0 1-1.242.97L5 20V5.562a2 2 0 0 1 1.515-1.94l4-1A2 2 0 0 1 13 4.561Z\"/>",
  "haushalt": "<circle cx=\"9\" cy=\"8\" r=\"3.2\"/><path d=\"M3 20c.6-3.4 3-5.4 6-5.4s5.4 2 6 5.4\"/><circle cx=\"17\" cy=\"9\" r=\"2.4\"/><path d=\"M16 14.6c2.6.1 4.3 1.8 5 4.6\"/>",
  "portale": "<rect x=\"3\" y=\"5\" width=\"18\" height=\"12\" rx=\"2\"/><path d=\"M8 21h8M12 17v4\"/><path d=\"M10 9l4 2-4 2z\"/>",
  "markt": "<path d=\"M4 9l1.5-5h13L20 9\"/><path d=\"M4 9h16v2a3 3 0 0 1-5.3 1.9A3 3 0 0 1 12 14a3 3 0 0 1-2.7-1.1A3 3 0 0 1 4 11z\"/><path d=\"M6 14v6h12v-6\"/>",
  "netz": "<circle cx=\"12\" cy=\"12\" r=\"9\"/><path d=\"M3 12h18M12 3c2.5 2.6 3.8 5.6 3.8 9S14.5 18.4 12 21c-2.5-2.6-3.8-5.6-3.8-9S9.5 5.6 12 3z\"/>",
  "werk": "<path d=\"M14.5 6.5a4 4 0 0 0-5.3 5.3L3.5 17.5l3 3 5.7-5.7a4 4 0 0 0 5.3-5.3l-2.6 2.6-2.4-.6-.6-2.4z\"/>",
  "konto": "<path d=\"M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z\"/><circle cx=\"12\" cy=\"12\" r=\"3\"/>",
  "mehr": "<circle cx=\"5\" cy=\"12\" r=\"1.6\"/><circle cx=\"12\" cy=\"12\" r=\"1.6\"/><circle cx=\"19\" cy=\"12\" r=\"1.6\"/>",
  "search": "<circle cx=\"11\" cy=\"11\" r=\"7\"/><path d=\"M20 20l-3.5-3.5\"/>",
  "phone": "<rect x=\"7\" y=\"2.5\" width=\"10\" height=\"19\" rx=\"2.5\"/><path d=\"M11 18.5h2\"/>",
  "tablet": "<rect x=\"4\" y=\"2.5\" width=\"16\" height=\"19\" rx=\"2.5\"/><path d=\"M11 18.5h2\"/>",
  "tv": "<rect x=\"2.5\" y=\"4\" width=\"19\" height=\"13\" rx=\"2\"/><path d=\"M8 21h8\"/>",
  "web": "<circle cx=\"12\" cy=\"12\" r=\"9\"/><path d=\"M3 12h18M12 3a14 14 0 0 1 0 18M12 3a14 14 0 0 0 0 18\"/>",
  "plus": "<path d=\"M12 5v14M5 12h14\"/>",
  "back": "<path d=\"M15 6l-6 6 6 6\"/>",
  "link": "<path d=\"M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1\"/><path d=\"M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1\"/>",
  "key": "<circle cx=\"8\" cy=\"15\" r=\"4\"/><path d=\"M11 12l9-9M17 6l3 3M15 8l2 2\"/>",
  "alert": "<path d=\"M12 3l9.5 17h-19z\"/><path d=\"M12 10v4M12 17.5v.01\"/>",
  "check": "<path d=\"M5 12.5l4.5 4.5L19 7.5\"/>",
  "shield": "<path d=\"M12 3l8 3v6c0 4.6-3.4 8.2-8 9-4.6-.8-8-4.4-8-9V6z\"/><path d=\"M8.5 12l2.5 2.5 4.5-5\"/>",
  "refresh": "<path d=\"M20 11a8 8 0 0 0-14.6-4.5L4 8\"/><path d=\"M4 4v4h4\"/><path d=\"M4 13a8 8 0 0 0 14.6 4.5L20 16\"/><path d=\"M20 20v-4h-4\"/>",
  "play": "<path d=\"M7 5l12 7-12 7z\"/>",
  "stop": "<rect x=\"6\" y=\"6\" width=\"12\" height=\"12\" rx=\"2\"/>",
  "download": "<path d=\"M12 4v11M7 10l5 5 5-5\"/><path d=\"M5 20h14\"/>",
  "upload": "<path d=\"M12 20V9M7 14l5-5 5 5\"/><path d=\"M5 4h14\"/>",
  "x": "<path d=\"M6 6l12 12M18 6L6 18\"/>"
};
