"""Motion hero: the kit draws the thing the ask is about (MOTION-14; yuigui spec/MOTION.md).

The film writer paints blobs for things with a body (a heart, a chicken, a car). So the plugin picks the hero object from
the ask with a word match against the names of the kit's drawn things (`api.thing(name, x, y, size)` in yuigui
site/public/demo/motion/kit.js), puts it in scene 1 itself, and tells scenes 2+ its name so they keep it on screen.
No model call, so no time added to the first scene. When nothing fits the ask, there is no hero and the film is made as before.
"""

from __future__ import annotations

import re
from typing import Optional

# kit thing -> words that mean it. Every name here must be a thing in kit.js (test_motion_hero checks it when the sibling yuigui checkout is there).
WORDS = {
    "dog": r"dogs?|pupp(?:y|ies)|canines?", "cat": r"cats?|kittens?|kitty|felines?", "fish": r"fish(?:es)?|salmon|trout|goldfish",
    "bird": r"birds?|sparrows?|robins?|parrots?|owls?|eagles?|pigeons?|songbirds?", "chicken": r"chickens?|hens?|roosters?|poultry",
    "cow": r"cows?|cattle|cows'|dairy|bulls?", "turtle": r"turtles?|tortoises?", "butterfl": None, "bee": r"bees?|beehives?|bumblebees?",
    "butterfly": r"butterfl(?:y|ies)|caterpillars?|moths?",
    "heart": r"hearts?|cardiac|heartbeats?", "lungs": r"lungs?|breathing|respiratory", "brain": r"brains?|neurons?|neural",
    "stomach": r"stomachs?|digestion|digestive", "tooth": r"teeth|tooth|dental|dentist", "bone": r"bones?|skeleton|skeletal",
    "eyeball": r"eyes?|eyeballs?|retina", "car": r"cars?|automobiles?|sedans?|vehicles?", "bus": r"buses|bus|buses",
    "truck": r"trucks?|lorry|lorries|freight", "plane": r"planes?|airplanes?|aeroplanes?|aircraft|jets?|airliners?|flights?",
    "boat": r"boats?|sailboats?|sailing|yachts?|ferr(?:y|ies)", "bicycle": r"bicycles?|bikes?|cycling|cyclists?",
    "train": r"trains?|locomotives?|railways?|railroads?", "rocket": r"rockets?|spacecraft|spaceships?|space shuttle",
    "hammer": r"hammers?|mallets?", "wrench": r"wrenches|wrench|spanners?", "scissors": r"scissors|shears", "saw": r"saws?|sawing|handsaws?",
    "screwdriver": r"screwdrivers?", "paintbrush": r"paint ?brush(?:es)?|paint(?:ing)? a (?:wall|room|house)", "key": r"keyholes?|keychains?|(?:door|house|car|front|room) keys?",
    "ladder": r"ladders?", "house": r"houses?|homes?(?! (?:screen|page|tab|button|row|view|feed))|apartments?|cottages?|mortgages?|rent(?:ing)?|landlords?",
    "castle": r"castles?|fortress(?:es)?|fortif\w+|medieval", "skyscraper": r"skyscrapers?|high-?rises?|office buildings?",
    "city": r"cit(?:y|ies)|skylines?|downtown", "colosseum": r"colosseum|coliseum|roman empire|romans?|rome|gladiators?",
    "church": r"churche?s?|cathedrals?|chapels?", "tent": r"tents?|camping|campsites?|campers?", "bridge": r"bridges?|suspension bridges?",
    "lighthouse": r"lighthouses?", "mug": r"mugs?|cups? of|coffee|tea cups?|teacups?|espresso|latte", "lemon": r"lemons?|citrus",
    "apple": r"apples?", "pizza": r"pizzas?", "bread": r"bread|loaf|loaves|baguettes?|sourdough", "egg": r"eggs?",
    "cake": r"cakes?|birthdays?|cupcakes?", "bottle": r"bottles?|wine|beer|brew(?:ing)?", "chair": r"chairs?|seating",
    "bed": r"beds?|sleep(?:ing)?|bedroom|mattress", "clock": r"clocks?|timers?|o'clock", "book": r"books?|novels?|libraries|library",
    "laptop": r"laptops?|notebooks? computers?", "camera": r"cameras?|photograph(?:y|s)?|photos?", "umbrella": r"umbrellas?|rain(?:y|ing)? gear",
    "battery": r"batter(?:y|ies)|chargers?", "plant": r"plants?|houseplants?|seedlings?|sprouts?|garden(?:ing)?|flowerpots?|photosynthesis",
    "coins": r"coins?|money|cash|savings?|dollars?|piggy bank", "box": r"boxes|box|parcels?|packages?|cartons?|shipping boxes?|deliver(?:y|ies)",
    "can": r"watering cans?", "tank": r"tanks?|reservoirs?|water levels?", "robot": r"robots?|androids?",
    "engine": r"engines?|pistons?|motors?|combustion|four-?stroke", "newsletter": r"newsletters?|magazines?|newspapers?",
    "envelope": r"envelopes?|e-?mails?|letters?|inbox|mail", "calendar": r"calendars?|schedules?|deadlines?|appointments?",
    "globe": r"globes?|continents?|planets?|the earth|the world|world map|countries",
}
del WORDS["butterfl"]
# things a passing mention should not pick over a body noun in the same ask (a lemon in a chicken recipe)
WEAK = {"lemon", "apple", "egg", "box", "coins", "envelope", "mug", "calendar", "globe", "clock", "key", "bed", "book", "camera", "bottle", "house", "city"}
SKIP = re.compile(r"\bapi\.three\b|\b3d\b|three\.js|\breal 3d\b", re.I)
COOK = re.compile(r"\b(roast(?:ed|ing)?|bak(?:e|ed|ing)|cook(?:ed|ing)?|recipe|oven|dinner|grill(?:ed|ing)?|fry|fried|garlic|stuff(?:ed|ing)?|carv(?:e|ing))\b", re.I)
_PATS = {n: re.compile(r"\b(?:" + w + r")\b", re.I) for n, w in WORDS.items()}


def pick(ask: str) -> Optional[str]:
    """The kit thing the ask is about, or None. The earliest word in the ask wins (the subject usually comes first)."""
    text = ask or ""
    if not text.strip() or SKIP.search(text):
        return None
    best: Optional[tuple[int, int, str]] = None
    for name, pat in _PATS.items():
        m = pat.search(text)
        if m:
            cand = (1 if name in WEAK else 0, m.start(), name)
            if best is None or cand < best:
                best = cand
    if best is None:
        return None
    name = best[2]
    if name == "chicken" and COOK.search(text):
        name = "roast"
    elif name == "roast":
        name = "chicken"
    return name


def hero_call(name: str, k: str = "api.seg(t, 0, 1.2)") -> str:
    """The line that draws the hero big in the middle band. Guarded: a phone with an older kit skips it."""
    return f'if (api.thing) api.thing("{name}", api.w / 2, api.h * 0.47, 300, {{k: {k}}});'


_LOOK = re.compile(r"^[ \t]*api\.look\([^)\n]*\)[ \t]*;?[ \t]*$", re.M)


def put_in(code: str, name: str, first: bool) -> str:
    """Scene code with the hero drawn in it, after the scene's look call (the look paints the background).
    Scene 1 draws the hero on; later scenes keep it on screen, already drawn, unless the scene already calls api.thing."""
    if "api.thing(" in code and not first:
        return code
    line = hero_call(name, "api.seg(t, 0, 1.2)" if first else "1")
    m = _LOOK.search(code)
    if m:
        return code[: m.end()] + "\n" + line + code[m.end():]
    return line + "\n" + code


OPENER_NOTE = ("\n\nHERO: the kit has ALREADY drawn the hero of this ask, a {name}, big in the middle of the screen (api.thing). Do not draw "
               "the {name} yourself and do not hide it. It is centred at (api.w/2, api.h*0.47) and about 300 px wide and tall: aim every callout at a spot inside that box. api.thing returns nothing and has no other fields. Write the rest of scene 1 around it: a title near the top, one or two api.callout "
               "labels on its parts (put each label in open space beside it, 12 px clear), something moving. Do not call api.look "
               "unless you want a different look; the hero is drawn after it.")
CONTINUE_NOTE = ("\n\nHERO: the hero of this ask is a {name}, drawn by the kit as api.thing(\"{name}\", x, y, size, {{k: 1}}) (x centre, y about "
                 "api.h*0.47, size 240 to 320; wrap it as `if (api.thing) api.thing(...)`; it returns nothing). Every scene you write keeps the {name} on screen "
                 "with that call, the same drawing, so the film reads as one thing: draw it first, then your callouts, arrows, counters and "
                 "captions around it. You may move it, scale it up with api.cam or api.focus, or draw a second api.thing beside it. Never "
                 "paint your own version of the {name}.")
