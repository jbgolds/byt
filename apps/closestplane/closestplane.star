"""Closest Plane — nearest ADS-B aircraft from YOUR receiver, with a look-direction arrow.

Data: dump1090/readsb aircraft.json served on your LAN (no API key, fully local).
Renders on 64x32: callsign, distance + compass, altitude, and an arrow rotated to
the RELATIVE bearing (0 = straight ahead of where the Tidbyt faces).
Set FACING to the compass direction your screen faces (0-359).
"""

load("encoding/json.star", "json")
load("http.star", "http")
load("math.star", "math")
load("render.star", "render")
load("schema.star", "schema")

DEFAULT_DATA_URL = "http://192.168.0.246:8091/aircraft.json"
DEFAULT_LOCATION = '{"lat": "40.73194", "lng": "-73.96111", "locality": "Brooklyn, NY"}'
DEFAULT_LAT = 40.73194
DEFAULT_LON = -73.96111
DEFAULT_FACING = "100"
DEFAULT_RADIUS_NM = "60"

TTL_SECONDS = 15  # local LAN data: refresh fast
STALE_SECONDS = 30  # drop records whose position is older than this

EARTH_NM = 3440.065  # mean earth radius in nautical miles
NM_TO_MI = 1.15078

ACCENT = "#ffb733"  # amber
DETAIL = "#8aa0c0"  # dim blue-grey

# Bold arrow pointing up (ahead). Rotated in-SVG by relative bearing:
# 0 = straight ahead, 90 = to your right, 180 = behind, 270 = to your left.
# Format args: (rotation degrees, fill color).
_ARROW_SVG = '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 20 20"><g transform="rotate(%d 10 10)"><path fill="%s" d="M8 19 L8 9 L4 13 L2 11 L10 3 L18 11 L16 13 L12 9 L12 19 Z"/></g></svg>'

COMPASS = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]

def _isnum(v):
    return type(v) == "int" or type(v) == "float"

def _isnum_str(s):
    if type(s) != "string" or not s:
        return False
    has_digit = False
    for c in s.elems():
        if c >= "0" and c <= "9":
            has_digit = True
        elif c != "." and c != "-":
            return False
    return has_digit

def _to_float(v, default):
    if _isnum(v):
        return float(v)
    if _isnum_str(v):
        return float(v)
    return default

def _haversine_nm(lat1, lon1, lat2, lon2):
    p1 = math.radians(lat1)
    p2 = math.radians(lat2)
    dp = math.radians(lat2 - lat1)
    dl = math.radians(lon2 - lon1)
    s1 = math.sin(dp / 2)
    s2 = math.sin(dl / 2)
    a = s1 * s1 + math.cos(p1) * math.cos(p2) * s2 * s2
    return 2 * EARTH_NM * math.asin(math.sqrt(a))

def _bearing(lat1, lon1, lat2, lon2):
    p1 = math.radians(lat1)
    p2 = math.radians(lat2)
    dl = math.radians(lon2 - lon1)
    y = math.sin(dl) * math.cos(p2)
    x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
    return (math.degrees(math.atan2(y, x)) + 360) % 360

def _compass(deg):
    return COMPASS[int(math.round(deg / 45.0)) % 8]

def _one_dp(x):
    v = int(math.round(x * 10))
    return "%d.%d" % (v // 10, v % 10)

def _callsign(ac):
    flight = ac.get("flight")
    if type(flight) == "string" and flight.strip():
        return flight.strip()
    hex = ac.get("hex")
    if type(hex) == "string" and hex:
        return hex.upper()
    return "UNKNOWN"

def _arrow(rel_brg, color):
    angle = int(math.round(rel_brg)) % 360
    return render.Image(src = _ARROW_SVG % (angle, color), width = 8, height = 8)

def _airline_label(flight, fr):
    f = flight.strip().upper() if type(flight) == "string" else ""
    if not f:
        return "UNKNOWN"
    name = None
    if type(fr) == "dict":
        al = fr.get("airline")
        if type(al) == "dict":
            n = al.get("name")
            if type(n) == "string" and n:
                name = n
    # Split leading operator letters from the rest (e.g. DAL123 -> DAL + 123).
    i = 0
    for c in f.elems():
        if c >= "A" and c <= "Z":
            i += 1
        else:
            break
    num = f[i:] if i < len(f) else ""
    op = f[:i] if i > 0 else f
    if name:
        short = name.split(" ")[0].upper()[:8]
        full = (short + " " + num) if num else short
        if len(full) <= 8:
            return full
    # Compact fallback always fits statically: RPA5788, DAL123.
    compact = op + num
    return compact if len(compact) <= 8 else f[:8]

ADSBDB_URL = "https://api.adsbdb.com/v0"

def _adsbdb_aircraft(hex):
    resp = http.get("%s/aircraft/%s" % (ADSBDB_URL, hex.upper()), ttl_seconds = 86400)
    if resp.status_code != 200:
        return None
    data = resp.json()
    if type(data) != "dict":
        return None
    r = data.get("response")
    if type(r) != "dict":
        return None
    ac = r.get("aircraft")
    if type(ac) != "dict":
        return None
    return ac

def _adsbdb_route(flight):
    resp = http.get("%s/callsign/%s" % (ADSBDB_URL, flight.strip().upper()), ttl_seconds = 3600)
    if resp.status_code != 200:
        return None
    data = resp.json()
    if type(data) != "dict":
        return None
    r = data.get("response")
    if type(r) != "dict":
        return None
    return r.get("flightroute")

def _line(text, font, color, width):
    # Static text when it fits (tb-8: 8 chars, tom-thumb: 11 chars);
    # scrolls only on overflow.
    if len(text) <= (8 if font == "tb-8" else 11):
        return render.Text(text, font = font, color = color)
    return render.Marquee(width = width, child = render.Text(text, font = font, color = color))

def _alt_compact(alt):
    if alt == "ground":
        return "GND"
    if not _isnum(alt):
        return "---"
    alt = int(alt)
    if alt >= 10000:
        return "%s.%sk" % (alt // 1000, (alt % 1000) // 100)
    return "%dft" % alt

def _select(aclist, lat, lon, radius_nm, only_airborne):
    best = None
    best_dist = 1e9
    for ac in aclist:
        if type(ac) != "dict":
            continue
        aclat = ac.get("lat")
        aclon = ac.get("lon")
        if not _isnum(aclat) or not _isnum(aclon):
            continue
        seen_pos = ac.get("seen_pos")
        if _isnum(seen_pos) and seen_pos > STALE_SECONDS:
            continue
        if only_airborne and ac.get("alt_baro") == "ground":
            continue
        dist = _haversine_nm(lat, lon, aclat, aclon)
        if dist > radius_nm:
            continue
        brg = _bearing(lat, lon, aclat, aclon)
        if dist < best_dist:
            best = (dist, brg, ac)
            best_dist = dist
    return best

def _render_aircraft(target, facing):
    dist, brg, ac = target
    rel = (brg - facing + 360) % 360
    if rel <= 180:
        rel_txt = "R%d" % int(math.round(rel))
    else:
        rel_txt = "L%d" % int(math.round(360 - rel))

    alt_txt = _alt_compact(ac.get("alt_baro"))

    # Aircraft type from adsbdb (cached 24h).
    type_txt = None
    ac_info = _adsbdb_aircraft(ac.get("hex") or "")
    if ac_info:
        t = ac_info.get("icao_type")
        if type(t) == "string" and t:
            type_txt = t

    line2 = ((type_txt + " ") if type_txt else "") + alt_txt

    # Route + airline from adsbdb callsign lookup (cached 1h).
    dist_mi = int(math.round(dist * NM_TO_MI))
    line3 = "%smi %s %s" % (dist_mi, _compass(brg), rel_txt)
    label = _callsign(ac)
    flight = ac.get("flight")
    if type(flight) == "string" and flight.strip():
        fr = _adsbdb_route(flight)
        label = _airline_label(flight, fr)
        if type(fr) == "dict":
            org = fr.get("origin") or {}
            dst = fr.get("destination") or {}
            oc = org.get("iata_code") if type(org) == "dict" else None
            dc = dst.get("iata_code") if type(dst) == "dict" else None
            if type(oc) == "string" and oc and type(dc) == "string" and dc:
                line3 = "%s>%s %smi" % (oc, dc, dist_mi)

    # Sweeping edge arrow: rides an ellipse around the text block so it always
    # sits on the rim in the relative direction of the plane. 0 = top/straight
    # ahead, 90 = right edge, 180 = bottom/behind, 270 = left edge.
    # Positioned with spacer boxes (Stack overlays, Column/Row place exactly).
    rad = math.radians(rel)
    ax = int(math.round(32 + 30 * math.sin(rad))) - 4
    ay = int(math.round(16 - 15 * math.cos(rad))) - 4
    ax = 0 if ax < 0 else (56 if ax > 56 else ax)
    ay = 0 if ay < 0 else (24 if ay > 24 else ay)
    arrow_row = render.Row(
        children = [
            render.Box(width = ax, height = 8),
            _arrow(rel, ACCENT),
        ],
    )
    overlay_children = [render.Box(width = 64, height = ay), arrow_row] if ay > 0 else [arrow_row]

    return render.Root(
        child = render.Stack(
            children = [
                render.Box(
                    width = 64,
                    height = 32,
                    child = render.Column(
                        main_align = "center",
                        cross_align = "center",
                        children = [
                            _line(label, "tb-8", ACCENT, 44),
                            _line(line2, "tom-thumb", DETAIL, 44),
                            _line(line3, "tom-thumb", DETAIL, 44),
                        ],
                    ),
                ),
                render.Column(children = overlay_children),
            ],
        ),
    )

def _frame_message(title, sub):
    children = [render.Text(title, font = "tb-8", color = DETAIL)]
    if sub:
        children.append(render.Text(sub, font = "tom-thumb", color = DETAIL))
    return render.Root(
        child = render.Box(
            child = render.Column(
                main_align = "center",
                cross_align = "center",
                children = children,
            ),
        ),
    )

def main(config):
    loc = json.decode(config.get("location") or DEFAULT_LOCATION)
    if type(loc) != "dict":
        loc = {}
    lat = _to_float(loc.get("lat"), DEFAULT_LAT)
    lon = _to_float(loc.get("lng"), DEFAULT_LON)

    facing = _to_float(config.get("facing") or DEFAULT_FACING, 100.0) % 360
    radius_nm = _to_float(config.get("radius_nm") or DEFAULT_RADIUS_NM, 60.0)
    only_airborne = config.bool("only_airborne", True)
    data_url = config.str("data_url", DEFAULT_DATA_URL)

    resp = http.get(data_url, ttl_seconds = TTL_SECONDS)
    if resp.status_code != 200:
        return _frame_message("NO SIGNAL", "rcvr offline")

    data = resp.json()
    aclist = data.get("aircraft") if type(data) == "dict" else None
    if type(aclist) != "list":
        return _frame_message("NO DATA", "bad feed")

    target = _select(aclist, lat, lon, radius_nm, only_airborne)
    if target == None:
        return _frame_message("SKY CLEAR", "no traffic")

    return _render_aircraft(target, facing)

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Location(
                id = "location",
                name = "Location",
                desc = "Receiver/observer location.",
                icon = "locationDot",
            ),
            schema.Text(
                id = "facing",
                name = "Facing (deg)",
                desc = "Compass direction the screen faces, 0-359.",
                icon = "compass",
                default = DEFAULT_FACING,
            ),
            schema.Text(
                id = "data_url",
                name = "ADS-B JSON URL",
                desc = "dump1090/readsb aircraft.json URL.",
                icon = "towerBroadcast",
                default = DEFAULT_DATA_URL,
            ),
            schema.Text(
                id = "radius_nm",
                name = "Radius (nm)",
                desc = "Max range in nautical miles.",
                icon = "rulerHorizontal",
                default = DEFAULT_RADIUS_NM,
            ),
            schema.Toggle(
                id = "only_airborne",
                name = "Airborne only",
                desc = "Skip aircraft on the ground.",
                icon = "planeUp",
                default = True,
            ),
        ],
    )
