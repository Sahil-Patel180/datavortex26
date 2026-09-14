from __future__ import annotations
from pathlib import Path

SRC_DIR = Path(__file__).resolve().parent
ROUND_DIR = SRC_DIR.parent
DATA_DIR = ROUND_DIR / "data"
RAW_DIR = DATA_DIR / "raw"
INTERIM_DIR = DATA_DIR / "interim"
PROCESSED_DIR = DATA_DIR / "processed"
REPORTS_DIR = ROUND_DIR / "reports"
FIGURES_DIR = REPORTS_DIR / "figures"

RAW_POSTS = RAW_DIR / "Social_Engine_Posts_Corrupted.csv"
RAW_USERS = RAW_DIR / "Social_Engine_Users.csv"

INTERIM_POSTS = INTERIM_DIR / "posts_stage1_normalised.csv"

CLEAN_POSTS_CSV = PROCESSED_DIR / "posts_clean.csv"
CLEAN_POSTS_JSON = PROCESSED_DIR / "posts_clean.json"
CLEAN_USERS_CSV = PROCESSED_DIR / "users_clean.csv"
HASHTAGS_CSV = PROCESSED_DIR / "hashtags.csv"
POST_HASHTAGS_CSV = PROCESSED_DIR / "post_hashtags.csv"
AUDIT_CSV = PROCESSED_DIR / "cleaning_audit.csv"

for _d in (INTERIM_DIR, PROCESSED_DIR, FIGURES_DIR):
    _d.mkdir(parents=True, exist_ok=True)

NULL_SENTINELS = {
    "", "null", "none", "nan", "n/a", "na", "-", "--", "?",
    "undefined", "nil", "\\n",
}

VALID_PLATFORMS = ["Facebook", "Instagram", "Reddit", "Twitter", "YouTube"]
UNKNOWN_PLATFORM = "Unknown"

TS_MIN = "2024-05-01"
TS_MAX = "2025-05-01"

LIKES_MAX = 5000
SHARES_MAX = 2000
COMMENTS_MAX = 1000

BRAND_PRODUCTS: dict[str, list[str]] = {
    "Nike": ["Air Force 1", "Air Jordan", "Air Max", "Dri-FIT", "Epic React",
             "FlyKnit", "React", "Zoom Pegasus"],
    "Adidas": ["Gazelle", "NMD", "Predator", "Samba", "Stan Smith",
               "Superstar", "Ultraboost", "Yeezy"],
    "Apple": ["AirPods Pro", "Apple Watch", "Mac Mini", "MacBook Pro",
              "Vision Pro", "iMac", "iPad Air", "iPhone 15"],
    "Samsung": ["Galaxy Buds", "Galaxy S25", "Galaxy Tab", "Galaxy Watch",
                "Galaxy Z Fold", "Neo QLED TV"],
    "Google": ["Chromebook", "Nest Hub", "Nest Thermostat", "Pixel 8",
               "Pixel Buds", "Pixel Tablet", "Pixel Watch"],
    "Microsoft": ["Surface Duo", "Surface Go", "Surface Laptop", "Surface Pro",
                  "Xbox Elite Controller", "Xbox Series X"],
    "Amazon": ["Echo Dot", "Eero WiFi", "Fire TV", "Fire Tablet", "Halo Band",
               "Kindle", "Ring Camera"],
    "Toyota": ["Camry", "Corolla", "Highlander", "Prius", "RAV4", "Sienna",
               "Tacoma", "Tundra"],
    "Pepsi": ["Crystal Pepsi", "Diet Pepsi", "Pepsi Lime", "Pepsi Max",
              "Pepsi Wild Cherry", "Pepsi Zero Sugar"],
    "Coca-Cola": ["Coca-Cola Cherry", "Coca-Cola Vanilla", "Coke Zero",
                  "Diet Coke", "Fanta", "Sprite"],
}
BRANDS = list(BRAND_PRODUCTS)
PRODUCT_TO_BRAND = {p: b for b, ps in BRAND_PRODUCTS.items() for p in ps}

VERDICT_LEXICON: dict[str, int] = {
    "absolutely loving it": 1,
    "worth every penny": 1,
    "exceeded my expectations": 1,
    "highly recommend": 1,
    "best purchase ever": 1,
    "disappointed with the quality": -1,
    "returning it asap": -1,
    "not worth the money": -1,
    "had issues with it": -1,
    "wouldn't recommend": -1,
    "would not recommend": -1,
    "it's okay": 0,
    "its okay": 0,
    "not bad": 0,
    "does the job": 0,
    "mixed feelings about it": 0,
    "as expected": 0,
}

OPENER_LEXICON: dict[str, int] = {
    "thrilled": 1,
    "loving it": 1,
    "delighted": 1,
    "can't contain my excitement": 1,
    "cannot contain my excitement": 1,
    "so happy": 1,
    "super excited": 1,
    "bummed out": -1,
    "feeling let down": -1,
    "cannot believe": -1,
    "sad to report": -1,
    "frustrated": -1,
    "fed up": -1,
    "not sure why": 0,
    "confused about": 0,
    "could someone explain": 0,
}

NEUTRAL_TAIL = "can't wait to see what's coming next"

SENTIMENT_LABELS = {1: "positive", 0: "neutral", -1: "negative"}

RANDOM_SEED = 42
