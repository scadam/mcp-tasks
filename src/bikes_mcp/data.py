"""Demo data: a curated list of specialized bicycles.

The payloads here are intentionally self-contained (no external API calls) so the
server can run anywhere — locally, in CI, or on Azure Functions — without
credentials or network access. Both tools render this data through their
respective Skybridge widgets, which bind to the tool ``structuredContent``.
"""

from __future__ import annotations

from typing import Any

# ---------------------------------------------------------------------------
# Tool 1 payload — production gravel/adventure bikes ready to ride.
# ---------------------------------------------------------------------------
GRAVEL_BIKES: list[dict[str, Any]] = [
    {
        "id": "grv-001",
        "name": "Terra Nova GRX",
        "brand": "Specialized",
        "category": "Gravel",
        "frame": "FACT 9r Carbon",
        "groupset": "Shimano GRX 820 1x12",
        "weightKg": 8.4,
        "wheelSize": "700c",
        "tireClearanceMm": 47,
        "priceUsd": 5200,
        "colorway": "Satin Forest / Gold",
        "highlights": [
            "Future Shock 2.0 micro-suspension",
            "Dropper-post routing",
            "Mudguard + rack mounts",
        ],
        "rating": 4.8,
        "imageColor": "#2f5d3a",
    },
    {
        "id": "grv-002",
        "name": "Aethos Gravel SL8",
        "brand": "Specialized",
        "category": "Gravel Race",
        "frame": "FACT 12r Carbon",
        "groupset": "SRAM Force XPLR AXS",
        "weightKg": 7.9,
        "wheelSize": "700c",
        "tireClearanceMm": 45,
        "priceUsd": 7800,
        "colorway": "Carbon / Chameleon",
        "highlights": [
            "Sub-8kg race build",
            "Wireless electronic shifting",
            "Aero cockpit",
        ],
        "rating": 4.9,
        "imageColor": "#4a3f8c",
    },
    {
        "id": "grv-003",
        "name": "Pathfinder ADV",
        "brand": "Specialized",
        "category": "Adventure",
        "frame": "Premium Aluminium",
        "groupset": "Shimano GRX 610 2x11",
        "weightKg": 10.2,
        "wheelSize": "650b",
        "tireClearanceMm": 53,
        "priceUsd": 3100,
        "colorway": "Desert Sand / Black",
        "highlights": [
            "Bikepacking-ready geometry",
            "Triple bottle mounts",
            "650b plus tires",
        ],
        "rating": 4.6,
        "imageColor": "#b5773a",
    },
    {
        "id": "grv-004",
        "name": "Crux Comp Limited",
        "brand": "Specialized",
        "category": "Cyclocross",
        "frame": "FACT 10r Carbon",
        "groupset": "SRAM Rival XPLR AXS",
        "weightKg": 8.1,
        "wheelSize": "700c",
        "tireClearanceMm": 42,
        "priceUsd": 4600,
        "colorway": "Gloss Red / Smoke",
        "highlights": [
            "Race-bred CX handling",
            "Featherweight carbon",
            "Tubeless-ready wheels",
        ],
        "rating": 4.7,
        "imageColor": "#a02c2c",
    },
]

# ---------------------------------------------------------------------------
# Tool 2 payload — bespoke, made-to-order custom builds (the "slow" workshop).
# ---------------------------------------------------------------------------
CUSTOM_BIKES: list[dict[str, Any]] = [
    {
        "id": "cst-101",
        "name": "Project Helios",
        "builder": "Specialized Custom Atelier",
        "discipline": "Endurance Road",
        "frameMaterial": "Titanium 3Al-2.5V",
        "finish": "Raw brushed / hand polish",
        "groupset": "SRAM Red AXS 2x12",
        "wheels": "Roval Alpinist CLX II",
        "buildTimeWeeks": 14,
        "priceUsd": 12400,
        "customizations": [
            "Geometry fit to rider scan",
            "Engraved head tube badge",
            "Integrated power meter",
        ],
        "rating": 5.0,
        "imageColor": "#6b7280",
    },
    {
        "id": "cst-102",
        "name": "Project Nighthawk",
        "builder": "Specialized Custom Atelier",
        "discipline": "All-Road",
        "frameMaterial": "FACT 12r Carbon (custom layup)",
        "finish": "Liquid black metallic",
        "groupset": "Shimano Dura-Ace Di2",
        "wheels": "Roval Rapide CLX II",
        "buildTimeWeeks": 16,
        "priceUsd": 14900,
        "customizations": [
            "Tuned compliance layup",
            "Hidden cockpit storage",
            "Custom paint mask artwork",
        ],
        "rating": 4.9,
        "imageColor": "#1f2937",
    },
    {
        "id": "cst-103",
        "name": "Project Summit",
        "builder": "Specialized Custom Atelier",
        "discipline": "Trail MTB",
        "frameMaterial": "FACT 11m Carbon",
        "finish": "Anodized teal fade",
        "groupset": "SRAM XX SL Eagle Transmission",
        "wheels": "Roval Traverse SL II",
        "buildTimeWeeks": 12,
        "priceUsd": 13200,
        "customizations": [
            "Custom suspension tune",
            "Rider-weight spring rate",
            "Personalized cockpit reach",
        ],
        "rating": 4.8,
        "imageColor": "#0f766e",
    },
]


def gravel_payload() -> dict[str, Any]:
    """Structured content for the gravel-bikes tool/widget."""
    bikes = GRAVEL_BIKES
    return {
        "title": "In-stock specialized gravel & adventure bikes",
        "currency": "USD",
        "count": len(bikes),
        "priceRange": {
            "min": min(b["priceUsd"] for b in bikes),
            "max": max(b["priceUsd"] for b in bikes),
        },
        "bikes": bikes,
    }


def custom_payload() -> dict[str, Any]:
    """Structured content for the custom-builds tool/widget."""
    bikes = CUSTOM_BIKES
    return {
        "title": "Made-to-order custom bicycle builds",
        "currency": "USD",
        "count": len(bikes),
        "priceRange": {
            "min": min(b["priceUsd"] for b in bikes),
            "max": max(b["priceUsd"] for b in bikes),
        },
        "leadTimeWeeks": {
            "min": min(b["buildTimeWeeks"] for b in bikes),
            "max": max(b["buildTimeWeeks"] for b in bikes),
        },
        "bikes": bikes,
    }
