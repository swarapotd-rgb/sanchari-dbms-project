#!/usr/bin/env python3
r"""
Sanchari - writes the MongoDB half of every review.

PostgreSQL keeps the countable part of a review (rating, visit date,
crowd level) in review_summary. The rest - the written text, a title,
aspect ratings that differ by kind of place, tags, tips, photos - is a
loose, nested, optional-heavy shape that suits a document store, so it
goes into MongoDB. review_summary.mongo_doc_id holds each document's _id.

Input : db/tools/reviews_export.csv   (made by export_reviews.sql)
Output: mongo/reviews.json            (154 documents, MongoDB Extended JSON)
        db/data/review_mongo_ids.csv  (which _id belongs to which SQL row;
                                       loaded by db/07e_seed_review_links.sql)

Run from the repo root (plain Python 3, nothing to install):

    python db/tools/make_review_docs.py

The text is built from sentence templates chosen to fit each review's
real data - place type, rating, crowd level, season, time spent, party
size, transport mode. Choices come from a hash of the review's key, not
random(), so every run writes exactly the same files.

Each _id is a valid 12-byte ObjectId made from the data, not random:
    4 bytes  created_at as Unix seconds   (ObjectId.getTimestamp() gives it back)
    5 bytes  'Sanch' in ASCII             (marks our seed documents)
    3 bytes  review_id                    (makes it unique)
"""

import csv
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CSV_IN = ROOT / "db" / "tools" / "reviews_export.csv"
JSON_OUT = ROOT / "mongo" / "reviews.json"
IDS_OUT = ROOT / "db" / "data" / "review_mongo_ids.csv"
MONSOON = {6, 7, 8, 9}


# ---------------------------------------------------------------------
#  Deterministic choice
# ---------------------------------------------------------------------
def h(*parts):
    return int(hashlib.sha1("|".join(map(str, parts)).encode()).hexdigest(), 16)


def pick(options, *key):
    return options[h(*key) % len(options)]


# ---------------------------------------------------------------------
#  What differs by kind of place
# ---------------------------------------------------------------------
#  noun       how the review refers to it
#  aspects    the sub-ratings that make sense for this kind of place -
#             the reason a fixed SQL table would not fit them well
#  good / bad details a reviewer would mention
#  tips       practical advice
#  captions   photo captions
TYPES = {
    "waterfall": dict(
        noun="waterfall",
        aspects=["scenery", "trail_condition", "safety", "cleanliness"],
        good=["the falls are a lovely sight and you can feel the spray from the viewing point",
              "the short walk down through the greenery is half the fun",
              "the sound of the water and the forest around it make it very calming"],
        bad=["the steps down are slippery and there is barely any railing",
             "plastic bottles were lying around near the viewing area",
             "the viewing point is small and everyone pushes for the same photo"],
        tips=["Wear shoes with grip - the steps get slippery.",
              "Go early in the morning for soft light and fewer people.",
              "Carry a small towel; the spray reaches the viewing deck."],
        captions=["The main fall from the viewing deck", "The path down to the falls"]),
    "viewpoint": dict(
        noun="viewpoint",
        aspects=["view", "access", "facilities", "crowd_comfort"],
        good=["the view over the valley is wide open and worth the climb",
              "watching the light change over the hills was the best part of the day",
              "there are benches and enough space to sit and take it all in"],
        bad=["mist covered most of the view while we were there",
             "the railing area is cramped and a little run-down",
             "vendors and loudspeakers take away from the calm"],
        tips=["Check the weather - on a misty day you will see very little.",
              "Sunset is the best time; reach 30 minutes before.",
              "Keep some change for parking."],
        captions=["View from the top", "Sunset over the hills"]),
    "trail": dict(
        noun="trek",
        aspects=["scenery", "trail_condition", "safety", "signage"],
        good=["the trail climbs steadily through shola forest and grassland",
              "the views from the top make every step worth it",
              "the path is well marked and the forest guards were helpful"],
        bad=["parts of the trail were washed out and muddy",
             "there is almost no signage at the forks",
             "it is steeper than the descriptions suggest"],
        tips=["Start before 7 so you are down before the afternoon heat.",
              "Carry at least two litres of water each.",
              "Check whether you need a forest department permit."],
        captions=["Halfway up the trail", "The summit"]),
    "lake": dict(
        noun="lake",
        aspects=["scenery", "cleanliness", "facilities", "value_for_money"],
        good=["the walk around the lake is peaceful, with plenty of birds",
              "the boating was relaxed and well organised",
              "the water reflecting the hills makes for great photos"],
        bad=["the edges of the lake need cleaning",
             "the boating queue was long and slow",
             "there is little shade on the walking path"],
        tips=["Evenings are pleasant for a walk around the lake.",
              "Buy boating tickets as soon as you arrive.",
              "Carry a cap - there is not much shade."],
        captions=["The lake in the evening", "Boats at the jetty"]),
    "garden": dict(
        noun="garden",
        aspects=["upkeep", "scenery", "facilities", "value_for_money"],
        good=["the lawns and flower beds are beautifully kept",
              "it is a good place to slow down for an hour",
              "the old trees give lots of shade"],
        bad=["several sections were closed for maintenance",
             "the toilets were not clean",
             "it gets noisy with large groups"],
        tips=["Mornings are cooler and quieter.",
              "Keep an hour for a proper walk around.",
              "The flower show season is the best time to visit."],
        captions=["The main lawn", "Flower beds near the entrance"]),
    "beach": dict(
        noun="beach",
        aspects=["cleanliness", "safety", "food_options", "crowd_comfort"],
        good=["the sand is clean and the sunset is beautiful",
              "the shacks nearby serve good, fresh food",
              "the water is calm near the shore and good for a paddle"],
        bad=["the sea was rough and swimming was not allowed",
             "litter near the entry point spoiled it a little",
             "it was too crowded to really relax"],
        tips=["Stay for the sunset.",
              "Follow the lifeguard flags - currents can be strong.",
              "Weekday evenings are much quieter than weekends."],
        captions=["Sunset on the beach", "The shoreline"]),
    "wildlife": dict(
        noun="safari",
        aspects=["sightings", "guide_quality", "organisation", "value_for_money"],
        good=["we saw elephants, deer and a lot of birds",
              "the guide knew the forest well and spotted animals we would have missed",
              "the early-morning drive through the forest was magical"],
        bad=["we saw very few animals on our drive",
             "booking and waiting at the counter took far too long",
             "the jeep was packed and noisy"],
        tips=["Book the morning slot online in advance.",
              "Wear dull colours and keep your voice down.",
              "Carry binoculars if you have them."],
        captions=["Elephants by the water", "Morning safari drive"]),
    "temple": dict(
        noun="temple",
        aspects=["atmosphere", "cleanliness", "queue_management", "accessibility"],
        good=["the carvings and the old architecture are stunning",
              "the atmosphere during the morning puja was very peaceful",
              "the temple was clean and well looked after"],
        bad=["the queue for darshan was very long",
             "the area around the temple was crowded and noisy",
             "it was hard to get information about the history"],
        tips=["Dress modestly; footwear has to be left outside.",
              "Visit early in the morning to avoid the queue.",
              "Photography is not allowed inside the sanctum."],
        captions=["The temple gopuram", "Carvings on the outer wall"]),
    "fort": dict(
        noun="fort",
        aspects=["history_info", "upkeep", "guide_quality", "value_for_money"],
        good=["the walls and gateways give a real sense of its history",
              "the views from the ramparts are excellent",
              "the information boards explain the history well"],
        bad=["parts of the fort are crumbling and closed off",
             "there is very little information on site",
             "it needs better upkeep and cleaning"],
        tips=["Hire a local guide - the stories make it come alive.",
              "Wear good shoes; the paths are uneven.",
              "Avoid the midday sun on the ramparts."],
        captions=["The main gateway", "View from the ramparts"]),
    "heritage": dict(
        noun="heritage site",
        aspects=["history_info", "upkeep", "guide_quality", "value_for_money"],
        good=["the architecture is breathtaking and full of detail",
              "walking through it feels like stepping back in time",
              "the site is well maintained by the ASI"],
        bad=["there is not enough shade or drinking water on site",
             "touts at the entrance were pushy",
             "some parts were closed for restoration"],
        tips=["Hire an approved guide at the ticket counter.",
              "Go early - the stone gets very hot by noon.",
              "Carry water and a cap."],
        captions=["The main structure", "Detail of the carvings"]),
    "museum": dict(
        noun="museum",
        aspects=["exhibits", "information", "upkeep", "value_for_money"],
        good=["the collection is interesting and well arranged",
              "the labels explain each exhibit clearly",
              "it is a good, cool break from the heat outside"],
        bad=["many labels were faded or missing",
             "the galleries felt dusty and poorly lit",
             "a few sections were closed without notice"],
        tips=["Check the weekly holiday before you go.",
              "Allow at least an hour to see it properly.",
              "Photography may need a separate ticket."],
        captions=["Inside the main gallery", "One of the exhibits"]),
    "market": dict(
        noun="market",
        aspects=["variety", "prices", "cleanliness", "crowd_comfort"],
        good=["there is a huge variety of local goods and food",
              "the stalls are colourful and full of life",
              "it is a great place to try local snacks"],
        bad=["prices for tourists were inflated",
             "the lanes are narrow and very crowded",
             "it was messy after the rain"],
        tips=["Bargain politely.", "Carry cash in small notes.", "Go in the evening when it is liveliest."],
        captions=["The market lanes", "A spice stall"]),
}

OPENERS = {
    5: ["{name} was the highlight of our day.",
        "Absolutely loved {name}.",
        "{name} is every bit as good as people say."],
    4: ["A very good {noun} and well worth a visit.",
        "We enjoyed {name} a lot.",
        "{name} is a lovely {noun}, with a few small issues."],
    3: ["{name} was okay - good in parts, disappointing in others.",
        "Mixed feelings about {name}.",
        "An average {noun}; nice, but not special."],
    2: ["{name} did not live up to the hype.",
        "Honestly, I was disappointed with {name}.",
        "Not the best {noun} we have seen."],
}
TITLES = {
    5: ["Unmissable", "Worth every minute", "The best part of the trip", "Simply beautiful"],
    4: ["Very good visit", "Well worth it", "Lovely, go early", "Glad we went"],
    3: ["Good, but go early", "Mixed experience", "Okay for a short stop", "Nice but overrated"],
    2: ["Disappointing", "Not worth the detour", "Needs better upkeep", "Skip if short on time"],
}
CLOSERS = {
    5: ["Highly recommended.", "Would happily come back.", "Don't miss it if you are in the area."],
    4: ["Recommended.", "Worth adding to your plan.", "Would visit again."],
    3: ["Fine if you are nearby, but don't plan a day around it.",
        "Go with low expectations and you'll enjoy it.",
        "Worth a short stop."],
    2: ["I wouldn't go out of my way for it.",
        "There are better places nearby.",
        "Needs a lot of improvement."],
}
CROWD = {
    1: ["It was quiet, almost empty when we arrived.", "Hardly anyone else was there."],
    2: ["There were only a few other visitors.", "Not crowded at all."],
    3: ["Moderately busy, but manageable.", "A fair number of people, nothing too bad."],
    4: ["It got quite crowded as the morning went on.", "Busy - lots of families and tour groups."],
    5: ["It was packed, so expect to share the view.", "Extremely crowded; expect queues."],
}
MODE = {
    "car": "We drove in", "bike": "We came on our bikes", "bus": "We came by bus",
    "train": "We came by train", "walk": "We walked over",
}


def cap(text):
    """Capitalise the first letter only (str.capitalize would lower-case 'ASI')."""
    return text[0].upper() + text[1:]


def band(rating):
    return int(round(float(rating)))


def object_id(created_at, review_id):
    ts = int(created_at.timestamp())
    return f"{ts:08x}" + b"Sanch".hex() + f"{int(review_id):06x}"


def make_doc(r):
    t = TYPES[r["place_type"]]
    key = (r["place_id"], r["user_id"], r["visited_on"])
    b = band(r["rating"])
    name, noun = r["place"], t["noun"]
    visited = datetime.strptime(r["visited_on"], "%Y-%m-%d").replace(tzinfo=timezone.utc)
    created = datetime.fromisoformat(r["created_at"].replace("+00", "+00:00"))
    crowd = int(r["crowd_level"])
    spent, typical = int(r["actual_duration_min"]), int(r["typical_visit_minutes"])
    monsoon = visited.month in MONSOON

    # ---- body: opener, details, crowd, time spent, trip, fee, closer
    s = [pick(OPENERS[b], *key, "open").format(name=name, noun=noun)]
    if b >= 4:
        s.append(cap(pick(t["good"], *key, "g1")) + ".")
        if b == 5:
            g2 = pick(t["good"], *key, "g2")
            if g2.lower() not in s[-1].lower():
                s.append("Also, " + g2 + ".")
    elif b == 3:
        s.append(cap(pick(t["good"], *key, "g1")) + ", but " + pick(t["bad"], *key, "b1") + ".")
    else:
        s.append(cap(pick(t["bad"], *key, "b1")) + ".")
        b2 = pick(t["bad"], *key, "b2")
        if b2.lower() not in s[-1].lower():
            s.append("On top of that, " + b2 + ".")
    if monsoon and r["place_type"] in ("waterfall", "lake"):
        s.append("We came during the monsoon, so the water was at its fullest.")
    elif monsoon and r["place_type"] in ("trail", "viewpoint", "beach"):
        s.append("It was the monsoon, so expect rain and slippery ground.")
    s.append(pick(CROWD[crowd], *key, "crowd"))
    if spent < typical - 5:
        s.append(f"We spent about {spent} minutes, which felt a little rushed.")
    elif spent > typical + 5:
        s.append(f"We ended up staying around {spent} minutes - longer than planned.")
    else:
        s.append(f"About {spent} minutes was the right amount of time.")
    if r["trip_id"]:
        party = int(r["party_size"])
        who = "on our own" if party == 1 else ("as a couple" if party == 2 else f"as a group of {party}")
        s.append(f"{MODE[r['mode_name']]} {who} as part of our \"{r['trip_title']}\" trip.")
    fee = float(r["fee_indian"])
    if fee == 0:
        s.append("Entry is free.")
    elif b >= 4:
        s.append(f"The ₹{fee:.0f} ticket is good value.")
    elif b == 2:
        s.append(f"Not worth the ₹{fee:.0f} ticket in its current state.")
    s.append(pick(CLOSERS[b], *key, "close"))

    # ---- aspects: near the overall rating; crowd-related ones follow crowd level
    aspects = {}
    for a in t["aspects"]:
        if a in ("crowd_comfort", "queue_management"):
            v = 6 - crowd + pick([-1, 0, 0, 1], *key, a)
        else:
            v = b + pick([-1, 0, 0, 0, 1], *key, a)
        aspects[a] = max(1, min(5, v))

    # ---- tags: facts about this visit
    tags = [r["place_type"]]
    if monsoon:
        tags.append("monsoon")
    if crowd <= 2:
        tags.append("quiet")
    if crowd >= 4:
        tags.append("crowded")
    if fee == 0:
        tags.append("free-entry")
    if r["requires_daylight"] == "t":
        tags.append("daylight-only")
    if r["trip_id"] and int(r["party_size"]) >= 3:
        tags.append("family-friendly" if b >= 4 else "group-visit")
    if b == 5:
        tags.append("must-see")

    oid = object_id(created, r["review_id"])
    doc = {
        "_id": {"$oid": oid},
        "review_id": int(r["review_id"]),
        "place_id": int(r["place_id"]),
        "user_id": int(r["user_id"]),
        "place": {"name": name, "type": r["place_type"],
                  "destination": r["destination"], "state": r["state"]},
        "author": {"display_name": r["display_name"]},
        "rating": float(r["rating"]),
        "visited_on": {"$date": visited.strftime("%Y-%m-%dT%H:%M:%SZ")},
        "title": pick(TITLES[b], *key, "title"),
        "body": " ".join(s),
        "aspects": aspects,
        "tags": tags,
        "helpful_votes": h(*key, "votes") % 25,
        "language": "en",
        "created_at": {"$date": created.strftime("%Y-%m-%dT%H:%M:%SZ")},
    }
    # optional fields - present only on some documents, which MongoDB allows
    if h(*key, "tip") % 2 == 0:
        doc["tip"] = pick(t["tips"], *key, "tipText")
    if h(*key, "photo") % 3 == 0:
        n = 1 + h(*key, "nphotos") % 2
        doc["photos"] = [{"path": f"photos/{oid}/{i + 1}.jpg",
                          "caption": t["captions"][i]} for i in range(n)]
    if r["trip_id"]:
        doc["trip"] = {"trip_id": int(r["trip_id"]), "title": r["trip_title"],
                       "party_size": int(r["party_size"]), "mode": r["mode_name"]}
    return doc


def main():
    with open(CSV_IN, encoding="utf-8", newline="") as f:
        rows = list(csv.DictReader(f))
    docs = [make_doc(r) for r in rows]

    JSON_OUT.parent.mkdir(exist_ok=True)
    with open(JSON_OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write("[\n")
        f.write(",\n".join(json.dumps(d, ensure_ascii=False) for d in docs))
        f.write("\n]\n")

    with open(IDS_OUT, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["email", "destination", "place", "visited_on", "mongo_doc_id"])
        for r, d in zip(rows, docs):
            w.writerow([r["email"], r["destination"], r["place"], r["visited_on"], d["_id"]["$oid"]])

    print(f"{len(docs)} documents -> {JSON_OUT.relative_to(ROOT)}")
    print(f"{len(docs)} links     -> {IDS_OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
