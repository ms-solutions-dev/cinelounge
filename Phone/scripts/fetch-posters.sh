#!/bin/zsh
# Fetches real posters from the library as test material.
#
# **Why real ones and not painted ones.** The series colour is computed from the
# poster, and what goes wrong there goes wrong on real images: on photographed Blu-ray
# cases whose blue packaging frame wins every extraction, and on images that are mostly
# grey. A painted test image has none of these properties and therefore proves nothing.
#
# They are stored at 96 × 96 — exactly the size the derivation computes on. That keeps
# the files small, and a poster can no longer be recognised in them.
#
#   scripts/fetch-posters.sh [count]
set -e
set -a; . ~/.jellyfin-claude 2>/dev/null; set +a
[[ -z "$JELLYFIN_API_KEY" ]] && { print "✗ ~/.jellyfin-claude not readable"; exit 1 }

COUNT=${1:-8}
TARGET=$(cd "$(dirname "$0")/.." && pwd)/Packages/DesignSystemPhone/Tests/DesignSystemPhoneTests/Fixtures
mkdir -p "$TARGET"

print "Fetching titles …"
curl -s --max-time 30 -H "Authorization: MediaBrowser Token=$JELLYFIN_API_KEY" \
  "$JELLYFIN_URL/Users/$JELLYFIN_USER_ID/Items?IncludeItemTypes=Series,Movie&Recursive=true&Limit=$COUNT&SortBy=Random&Fields=PrimaryImageAspectRatio" \
  | python3 -c '
import json, sys
for item in json.load(sys.stdin)["Items"]:
    print(item["Id"], item["Name"].replace(" ", "_")[:40], sep="\t")
' > /tmp/plakate.txt

while IFS=$'\t' read -r id name; do
  curl -s --max-time 30 -o "/tmp/$id.jpg" \
    "$JELLYFIN_URL/Items/$id/Images/Primary?fillWidth=96&fillHeight=96&quality=90"
  [[ -s "/tmp/$id.jpg" ]] || { print "  ✗ $name"; continue }
  python3 - "$id" "$name" "$TARGET" <<'PY'
import sys
from PIL import Image
ident, name, target = sys.argv[1], sys.argv[2], sys.argv[3]
image = Image.open(f"/tmp/{ident}.jpg").convert("RGB").resize((96, 96))
image.save(f"{target}/{name}.png")
print(f"  ✓ {name}.png")
PY
  rm -f "/tmp/$id.jpg"
done < /tmp/plakate.txt
rm -f /tmp/plakate.txt
print "\nStored in $TARGET"
