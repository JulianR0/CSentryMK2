## Sentry Mk. II

This script adds a new monster: A colored sentry on which you can attach any weapon of your choice.

To install, download the .as file and copy to **svencoop_addon/scripts/maps**. Then add "map_script sentryMK2.as" to the end of your map cfg to enable this.

If you have cheat access, you can now use `create monster_sentry_mk2 1` to spawn a friendly sentry. Press **+use** on it to open the weapon slot, and **+use** once again to attach your current weapon to the sentry. After the weapon have been given to the sentry, it will activate itself and start attacking enemies.

Of course, if you want, you can skip the "1" and just spawn an enemy sentry `create monster_sentry_mk2`. A red enemy sentry will spawn with a random weapon, it may be a harmless crowbar or a destructive minigun.

A basic FGD file is also included in this reposity to add enemy sentries to your maps with ease.

## Known caveats

The sentry can only accept vanilla Sven Co-op weapons. Any custom weapon is unsupported and will be refused by the sentry.

## Thanks

Inspired by Outerbeast's Deployable Sentries.
Thanks to Solokiller for the OP4 Barnacle Grapple code.
