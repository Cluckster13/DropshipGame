class_name Damage
extends RefCounted
## Damage types, and one helper that deals damage to anything (troops,
## vehicles, aircraft) with the right type.
##
## Armour tiers live on each Vehicle as a multiplier per type:
##   BULLET - rifles, MGs, door guns
##   AT     - rockets and tank shells
##   CHARGE - demolition charge planted by infantry
##   FLAK   - anti-air cannon rounds

enum Type { BULLET, AT, CHARGE, FLAK }

## Deal `amount` of `type` damage to target, if it can take damage

static func apply(target: Object, amount: float, source: Node, type: Type = Type.BULLET) -> void:
	if not is_instance_valid(target) or not target.has_method("take_damage"):
		return
	if target is Vehicle:
		target.take_damage(amount, source, type)
	elif target is HeliBase:
		# Anything heavier than a rifle round ignores the cabin armour
		target.take_damage(amount, source, type != Type.BULLET)
	else:
		target.take_damage(amount, source)
