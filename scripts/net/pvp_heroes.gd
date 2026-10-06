class_name PvpHeroes
extends RefCounted
## The heroes of a PvP match: the roster's heroes at a fixed strength (the equivalent of level 30,
## with the default five-spell loadout and no runes). The level is never shown: it only sets the
## kit and the stats, the same for everyone.

const LEVEL := 30
const ROSTER := "res://data/progression/roster.tres"


static func roster() -> Roster:
	return load(ROSTER) as Roster


static func hero_count() -> int:
	return roster().heroes.size()


## The hero's name for the lobby.
static func hero_name(hero_index: int) -> String:
	return TranslationServer.translate(roster().heroes[hero_index].display_name())


## The hero's unit and its permanent modifiers at the PvP strength.
static func build(hero_index: int) -> Dictionary:
	var hero := roster().heroes[clampi(hero_index, 0, hero_count() - 1)]
	var record := HeroRecord.new(hero)
	record.level = LEVEL
	record.settle_loadout()
	return {"unit": record.battle_unit_data(), "modifiers": record.modifiers()}
