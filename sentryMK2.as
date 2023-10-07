/** Sentry Mk2
*
* by Giegue
* 
* "Mk2" is just a fancy name. This a special sentry that allows players
* to attach their weapons to the turret, your very own "Do It Yourself" sentry.
* 
* Ever wondered a shotgun sentry? A minigun sentry? A barnacle sentry?
* Heh. Time to build.
* 
* Inspired by Outerbeast's deployable sentries.
* Thanks to Solokiller for the OP4 barnacle grapple code.
*
* Add this to your map cfg: "map_script sentry2" to start.
* Then just spawn "monster_sentry_mk2" in your map.
* 
* If you have cheat access, creating allied sentries will allow players
* to attach their weapons to the sentry.
* > create monster_sentry_mk2 1
* 
* You can also skip the "1" to spawn enemy sentries, which will create
* sentries with random weapons.
*/

// Sentry spawnflags
const int SF_SENTRY_STARTDAMAGE = ( 1 << 5 ); // If sentry is inactive, auto-start if it takes damage
const int SF_SENTRY_STARTOFF = ( 1 << 6 ); // Do not turn on automatically after spawn
const int SF_SENTRY_CANDISARM = ( 1 << 7 ); // Allow dismantling of enemy turrets
const int SF_SENTRY_IGNORE_LOS = ( 1 << 8 ); // Ignore Line of Sight - Always fire

// Sentry Animations
enum e_sequences
{
	IDLE = 0, // idle, turret is sleeping
	FIRE, // active, turret is attacking
	SPIN, // idle, turret is awake but without a target
	DEPLOY, // activating
	RETIRE, // deactivating
	DIE, // dead.bsp
	SPIN_UP, // minigun only, barrel is spinning up
	SPIN_DOWN,  // minigun only, spinning down
	WEAPON_OPEN, // opening weapon slot
	WEAPON_CLOSE // closing weapon slot
};

// Sentry Weapons
enum e_weapons
{
	W_NONE = 3,
	W_CROWBAR,
	W_WRENCH,
	W_MEDKIT,
	W_GRAPPLE,
	W_GLOCK,
	W_PYTHON,
	W_UZI,
	W_UZIAKIMBO,
	W_DESERT_EAGLE,
	W_MP5,
	W_SHOTGUN,
	W_CROSSBOW,
	W_M16,
	W_RPG,
	W_GAUSS,
	W_EGON,
	W_HORNETGUN,
	W_SNIPERRIFLE,
	W_M249,
	W_SPORELAUNCHER,
	W_SHOCKRIFLE,
	W_DISPLACER,
	W_MINIGUN
};

// Sentry fire states
enum e_firestate
{
	STATE_OFF = 0,
	STATE_FIRING,
	STATE_READY // for minigun, barrel is already spun up
};

// bodygroup of rpg missile
const int B_RPG = 27;

class CSentryMK2 : ScriptBaseMonsterEntity
{
	float m_flStartYaw; // starting angle
	float m_flPingTime; // when to emit next "ping" sound
	float m_fTurnRate; // current turning speed
	float m_flLastSight; // the last time the turret could see its enemy
	float m_flNextFire; // when to fire next shoot
	
	int m_iMinPitch; // how low can the turret barrel go
	int m_iBaseTurnRate; // how fast can the turret turn
	int m_iAttackRange; // how far can the turret see (and attack)
	int m_iWeapon; // current sentry weapon
	int m_iWeaponState; // misc var to keep track of various states during fire
	int m_iClip; // how many bullets per burst-fire (used for M16)
	
	Vector m_vecGoalAngles; // angles to where the turret must look at
	Vector m_vecCurAngles; // current turret angles
	Vector m_vecLastSight; // where the enemy was located the last time it could see it
	
	int m_Smoke; // model index of the smoke sprite, used for death effect
	int m_BodyGibs; // model index of the metal gibs, used for death effect
	int m_Beam; // model index of the laser sprite, used for gauss fire effect
	
	CBeam@ m_pBeam; // for egon: "sinus" shaped laser. for grapple: tongue effect
	CBeam@ m_pNoise; // laser entity, used for egon attack
	CSprite@ m_pSprite; // "cloud" sprite used when egon hits something it can hurt
	CSentryTongue@ m_pTip; // "tip" of grapple tongue
	
	// beware, if spawned from a squadmaker, the owner will be the squadmaker instead of a player
	EHandle m_hPlayerOwner; // owner of this sentry (player)
	
	// Initialize the turret
	void Spawn()
	{
		// obligatory
		Precache();
		g_EntityFuncs.SetModel( self, "models/deployable_sentry.mdl" );
		
		// gun position
		self.pev.view_ofs.z = 48;
		
		// lol
		self.m_bloodColor = DONT_BLEED;
		
		// set a default health if none is specified
		if ( self.pev.health == 0 )
			self.pev.health = g_EngineFuncs.CVarGetFloat( "sk_sentry_health" ) * 2;
		self.pev.max_health = self.pev.health;
		
		// monster properties
		self.pev.movetype = MOVETYPE_STEP;
		self.pev.gravity = 1;
		self.pev.solid = SOLID_SLIDEBOX;
		self.pev.takedamage = DAMAGE_AIM;
		self.pev.flags |= FL_MONSTER;
		
		// prepare a few vars for first use
		m_iMinPitch = -60;
		m_flStartYaw = self.pev.angles.y;
		m_vecGoalAngles.x = 0;
		m_iBaseTurnRate = 30;
		
		// if no attack range defined, set default
		if ( m_iAttackRange == 0 )
			m_iAttackRange = 1200;
		
		// spawned sentry is ally or enemy? setup accordingly
		if ( self.IsPlayerAlly() )
		{
			// save player owner if it exists
			if ( self.pev.owner !is null )
			{
				self.pev.colormap = self.pev.owner.vars.colormap; // pass player's color to sentry
				m_hPlayerOwner = g_EntityFuncs.Instance( self.pev.owner );
				@self.pev.owner = null; // to keep collisions going
			}
			
			// start with no weapon, setup model bodygroup
			self.pev.body = m_iWeapon = W_NONE;
			
			// stay asleep
			SetThink( ThinkFunction( SleepThink ) );
			self.pev.nextthink = g_Engine.time + 0.1;
			
			// wait for +use if ally
			SetUse( UseFunction( OpenUse ) );
		}
		else
		{
			// if no starting weapon, pick a random one
			if ( m_iWeapon == 0 )
				m_iWeapon = Math.RandomLong( W_CROWBAR, W_MINIGUN );
			self.pev.body = m_iWeapon;
			
			// turn on
			if ( !self.pev.SpawnFlagBitSet( SF_SENTRY_STARTOFF ) )
			{
				SetThink( ThinkFunction( Deploy ) );
				self.pev.nextthink = g_Engine.time + 0.3;
			}
			else
			{
				// wait until trigger
				SetUse( UseFunction( TurretUse ) );
				
				SetThink( ThinkFunction( SleepThink ) );
				self.pev.nextthink = g_Engine.time + 0.1;
			}
		}
		
		// reset to idle
		SetSentryAnim( IDLE );
		
		// controllers
		self.SetBoneController( 0, 0 );
		self.SetBoneController( 1, 0 );
		
		// can search new targets in a full 360 angle
		self.m_flFieldOfView = VIEW_FIELD_FULL;
		
		// BBOX size
		g_EntityFuncs.SetSize( self.pev, Vector( -16, -16, -1 ), Vector( 16, 16, 64 ) );
		
		// link to world then drop to floor
		g_EntityFuncs.SetOrigin( self, self.pev.origin );
		g_EngineFuncs.DropToFloor( self.edict() );
		
		// starting name
		if ( string( self.m_FormattedName ).Length() == 0 )
			self.m_FormattedName = "Sentry MkII";
		
		self.StudioFrameAdvance();
		
		// HACK - custom monsters cannot override the IsMachine() method.
		// The IsMachine() BaseClass is a check by CLASSNAME!
		//
		// YES, CLASSNAME! WHY!?
		//
		// Cheat the game into thinking that this is a "machine" to prevent
		// player medkit from working. Machines are supposed to be healed
		// with the wrench, not with the medkit! -Giegue
		g_EntityFuncs.DispatchKeyValue( self.edict(), "classname", "monster_sentry" );
	}
	
	// Precache all resources
	void Precache()
	{
		g_Game.PrecacheModel( "models/deployable_sentry.mdl" );
		m_Smoke = g_Game.PrecacheModel( "sprites/steam1.spr" );
		m_Beam = g_Game.PrecacheModel( "sprites/laserbeam.spr" );
		m_BodyGibs = g_Game.PrecacheModel( "models/metalplategibs_green.mdl" ); // it should be red but there is no appropiate model for it
		g_Game.PrecacheOther( "sentry_tongue" );
		
		g_SoundSystem.PrecacheSound( "turret/tu_fire1.wav" );
		g_SoundSystem.PrecacheSound( "turret/tu_ping.wav" );
		g_SoundSystem.PrecacheSound( "turret/tu_active2.wav" );
		g_SoundSystem.PrecacheSound( "turret/tu_die.wav" );
		g_SoundSystem.PrecacheSound( "turret/tu_die2.wav" );
		g_SoundSystem.PrecacheSound( "turret/tu_die3.wav" );
		g_SoundSystem.PrecacheSound( "turret/tu_deploy.wav" );
		g_SoundSystem.PrecacheSound( "turret/tu_spinup.wav" );
		g_SoundSystem.PrecacheSound( "turret/tu_spindown.wav" );
		g_SoundSystem.PrecacheSound( "turret/tu_search.wav" );
		g_SoundSystem.PrecacheSound( "turret/tu_alert.wav" );
		
		// strange, these aren't precached by default?
		g_SoundSystem.PrecacheSound( "weapons/m16_3round.wav" ); 
		g_SoundSystem.PrecacheSound( "barnacle/bcl_chew3.wav" );
	}
	
	// Classification of the monster
	int Classify()
	{
		// player ally override
		if ( self.IsPlayerAlly() )
			return CLASS_PLAYER_ALLY;
		
		// allow custom monster classifications
		if ( self.m_fOverrideClass )
			return self.m_iClassSelection;
		
		// default
		return CLASS_MACHINE;
	}
	
	// Process keyvalues
	bool KeyValue( const string& in szKey, const string& in szValue )
	{
		if ( szKey == "attackrange" )
		{
			m_iAttackRange = atoi( szValue );
			return true;
		}
		else if ( szKey == "weapon" )
		{
			m_iWeapon = atoi( szValue );
			
			// clamp to valid values
			if ( m_iWeapon != 0 )
				m_iWeapon = Math.clamp( W_CROWBAR, W_MINIGUN, m_iWeapon );
			
			return true;
		}
		else
			return BaseClass.KeyValue( szKey, szValue );
	}
	
	// Make +use-able if ally
	int ObjectCaps()
	{
		int oCaps = BaseClass.ObjectCaps();
		if ( self.IsPlayerAlly() || self.pev.SpawnFlagBitSet( SF_SENTRY_CANDISARM ) )
			oCaps |= FCAP_IMPULSE_USE;
		
		return oCaps; 
	}
	
	// Entity is being removed from world, clean up effects
	void OnDestroy()
	{
		CleanFireEffects();
	}
	
	// The actual cleaning
	void CleanFireEffects()
	{
		if ( m_iWeaponState == STATE_FIRING )
		{
			switch ( m_iWeapon )
			{
				case W_EGON: EgonEnd(); break;
				case W_GRAPPLE: GrappleEnd(); break;
				case W_M16: m_iClip = 3; break; // reload
			}
		}
	}
	
	// Trigger to awaken
	void TurretUse( CBaseEntity@ pActivator, CBaseEntity@ pCaller, USE_TYPE useType, float value )
	{
		// Or to disarm
		if ( pActivator.IsPlayer() && self.IRelationship( pActivator ) != R_AL && self.pev.SpawnFlagBitSet( SF_SENTRY_CANDISARM ) )
		{
			if ( self.pev.sequence == GetSequence( IDLE ) )
				OpenDisarm( pActivator, pCaller, useType, value );
			else
			{
				// Before we retrace, make sure that we are spun down.
				m_flLastSight = 0;
				SetThink( ThinkFunction( Retire ) );
			}
		}
		else
		{
			self.pev.nextthink = g_Engine.time + 0.1;
			SetThink( ThinkFunction( Deploy ) );
		}
		
		SetUse( null ); // only once
	}
	
	// Dummy think for animation purposes
	void SleepThink()
	{
		self.pev.nextthink = g_Engine.time + 0.1;
		self.StudioFrameAdvance();
	}
	
	// Open weapon slot for insertion
	void OpenUse( CBaseEntity@ pActivator, CBaseEntity@ pCaller, USE_TYPE useType, float value )
	{
		// players only, and must be alive
		if ( pActivator.IsPlayer() && pActivator.IsAlive() )
		{
			// prepare to retrieve weapon
			SetUse( UseFunction( CloseUse ) );
			SetThink( ThinkFunction( OpenThink ) );
			
			self.pev.nextthink = g_Engine.time + 0.1;
			self.StudioFrameAdvance();
		}
	}
	
	// Open weapon slot for disarming
	void OpenDisarm( CBaseEntity@ pActivator, CBaseEntity@ pCaller, USE_TYPE useType, float value )
	{
		// players only, and must be alive
		if ( pActivator.IsPlayer() && pActivator.IsAlive() )
		{
			// retire the weapon first if not in idle
			if ( self.pev.sequence != GetSequence( IDLE ) )
			{
				m_flLastSight = 0;
				SetThink( ThinkFunction( Retire ) );
			}
			else
			{
				// prepare to retrieve weapon
				SetThink( ThinkFunction( OpenDisarmThink ) );
				
				self.pev.nextthink = g_Engine.time + 0.1;
				self.StudioFrameAdvance();
			}
			
			SetUse( null );
		}
	}
	
	// Why can't I make the animation work properly? :C
	void OpenThink()
	{
		// open up
		SetSentryAnim( WEAPON_OPEN );
		
		self.pev.nextthink = g_Engine.time + 0.1;
		self.StudioFrameAdvance();
	}
	
	void OpenDisarmThink()
	{
		// open up
		SetSentryAnim( WEAPON_OPEN );
		
		self.pev.nextthink = g_Engine.time + 0.1;
		self.StudioFrameAdvance();
		
		if ( self.m_fSequenceFinished )
			SetTouch( TouchFunction( DisarmTouch ) );
	}
	
	void DisarmTouch( CBaseEntity@ pOther )
	{
		if ( pOther.IsPlayer() && pOther.IsAlive() )
		{
			CBasePlayer@ pPlayer = cast< CBasePlayer@ >( pOther );
			
			string weaponClassname;
			
			// give sentry weapon to player
			switch ( m_iWeapon )
			{
				case W_CROWBAR: weaponClassname = "weapon_crowbar"; break;
				case W_GLOCK: weaponClassname = "weapon_9mmhandgun"; break;
				case W_PYTHON: weaponClassname = "weapon_357"; break;
				case W_MP5: weaponClassname = "weapon_9mmAR"; break;
				case W_CROSSBOW: weaponClassname = "weapon_crossbow"; break;
				case W_SHOTGUN: weaponClassname = "weapon_shotgun"; break;
				case W_RPG: weaponClassname = "weapon_rpg"; break;
				case W_GAUSS: weaponClassname = "weapon_gauss"; break;
				case W_EGON: weaponClassname = "weapon_egon"; break;
				case W_HORNETGUN: weaponClassname = "weapon_hornetgun"; break;
				case W_UZI: weaponClassname = "weapon_uzi"; break;
				case W_UZIAKIMBO: weaponClassname = "weapon_uziakimbo"; break;
				case W_MEDKIT: weaponClassname = "weapon_medkit"; break;
				case W_WRENCH: weaponClassname = "weapon_pipewrench"; break;
				case W_MINIGUN: weaponClassname = "weapon_minigun"; break;
				case W_GRAPPLE: weaponClassname = "weapon_grapple"; break;
				case W_SNIPERRIFLE: weaponClassname = "weapon_sniperrifle"; break;
				case W_M249: weaponClassname = "weapon_m249"; break;
				case W_M16: weaponClassname = "weapon_m16"; break;
				case W_SPORELAUNCHER: weaponClassname = "weapon_sporelauncher"; break;
				case W_DESERT_EAGLE: weaponClassname = "weapon_eagle"; break;
				case W_SHOCKRIFLE: weaponClassname = "weapon_shockrifle"; break;
				case W_DISPLACER: weaponClassname = "weapon_displacer"; break;
			}
			
			CBaseEntity@ pWeapon = g_EntityFuncs.Create( weaponClassname, pPlayer.pev.origin, g_vecZero, true );
			pWeapon.pev.spawnflags = SF_NORESPAWN | SF_CREATEDWEAPON;
			g_EntityFuncs.DispatchSpawn( pWeapon.edict() );
			
			self.pev.body = m_iWeapon = W_NONE;
			SetTouch( null );
			
			SetSentryAnim( WEAPON_CLOSE );
			self.pev.nextthink = g_Engine.time + 0.1;
			SetThink( ThinkFunction( CloseDisarmThink ) );
		}
	}
	
	// Check weapon
	void CloseUse( CBaseEntity@ pActivator, CBaseEntity@ pCaller, USE_TYPE useType, float value )
	{
		// same old, same check
		if ( pActivator.IsPlayer() && pActivator.IsAlive() )
		{
			// if just opened, wait for current animation to finish
			if ( self.m_fSequenceFinished )
			{
				// get player current weapon
				CBasePlayer@ pPlayer = cast< CBasePlayer@ >( pActivator );
				CBasePlayerWeapon@ pWeapon = cast< CBasePlayerWeapon@ >( pPlayer.m_hActiveItem.GetEntity() );
				if ( pWeapon !is null )
				{
					int newWeapon = W_NONE;
					
					// only these weapons are valid
					switch ( pWeapon.m_iId )
					{
						case WEAPON_CROWBAR: newWeapon = W_CROWBAR; break;
						case WEAPON_GLOCK: newWeapon = W_GLOCK; break;
						case WEAPON_PYTHON: newWeapon = W_PYTHON; break;
						case WEAPON_MP5: newWeapon = W_MP5; break;
						case WEAPON_CROSSBOW: newWeapon = W_CROSSBOW; break;
						case WEAPON_SHOTGUN: newWeapon = W_SHOTGUN; break;
						case WEAPON_RPG: newWeapon = W_RPG; break;
						case WEAPON_GAUSS: newWeapon = W_GAUSS; break;
						case WEAPON_EGON: newWeapon = W_EGON; break;
						case WEAPON_HORNETGUN: newWeapon = W_HORNETGUN; break;
						case WEAPON_UZI:
						{
							// check player anim for single or akimbo
							if ( pPlayer.get_m_szAnimExtension() == 'uzis' )
								newWeapon = W_UZIAKIMBO;
							else
								newWeapon = W_UZI;
							break;
						}
						case WEAPON_MEDKIT: newWeapon = W_MEDKIT; break;
						case WEAPON_PIPEWRENCH: newWeapon = W_WRENCH; break;
						case WEAPON_MINIGUN: newWeapon = W_MINIGUN; break;
						case WEAPON_GRAPPLE: newWeapon = W_GRAPPLE; break;
						case WEAPON_SNIPERRIFLE: newWeapon = W_SNIPERRIFLE; break;
						case WEAPON_M249: newWeapon = W_M249; break;
						case WEAPON_M16: newWeapon = W_M16; break;
						case WEAPON_SPORELAUNCHER: newWeapon = W_SPORELAUNCHER; break;
						case WEAPON_DESERT_EAGLE: newWeapon = W_DESERT_EAGLE; break;
						case WEAPON_SHOCKRIFLE: newWeapon = W_SHOCKRIFLE; break;
						case WEAPON_DISPLACER: newWeapon = W_DISPLACER; break;
					}
					
					// not supported, any custom weapon will also fall here
					if ( newWeapon == W_NONE )
					{
						g_PlayerFuncs.ClientPrint( pPlayer, HUD_PRINTCENTER, "Deploy sentry N/A: Unsupported weapon\n" );
						return;
					}
					
					// set new sentry weapon
					self.pev.body = m_iWeapon = newWeapon;
					if ( m_iWeapon == W_M16 )
						m_iClip = 3; // starting clip
					
					// remove the player weapon
					g_EntityFuncs.Remove( pWeapon );
					
					// close and deploy
					SetSentryAnim( WEAPON_CLOSE );
					
					self.pev.nextthink = g_Engine.time + 0.1;
					SetThink( ThinkFunction( CloseThink ) );
					SetUse( null ); // not usable again
				}
				else
				{
					// no weapon, no deploy
					g_PlayerFuncs.ClientPrint( pPlayer, HUD_PRINTCENTER, "Deploy sentry N/A: No weapon\n" );
				}
			}
		}
	}
	
	// Close weapon slot and prepare to deploy
	void CloseThink()
	{
		self.pev.nextthink = g_Engine.time + 0.1;
		self.StudioFrameAdvance();
		
		// deploy after animation is complete
		if ( self.m_fSequenceFinished )
		{
			self.pev.nextthink = g_Engine.time + 0.3;
			SetThink( ThinkFunction( Deploy ) );
		}
	}
	
	void CloseDisarmThink()
	{
		self.pev.nextthink = g_Engine.time + 0.1;
		self.StudioFrameAdvance();
		
		// dummy sentry after it's done
		if ( self.m_fSequenceFinished )
			SetThink( null );
	}
	
	// Deactivate the turret
	void Retire()
	{
		// make the turret level
		m_vecGoalAngles.x = 0;
		m_vecGoalAngles.y = m_flStartYaw;
		
		self.pev.nextthink = g_Engine.time + 0.1;
		
		self.StudioFrameAdvance();
		
		if ( !MoveTurret() )
		{
			if ( self.pev.sequence != GetSequence( RETIRE ) )
			{
				SetSentryAnim( RETIRE, true );
				g_SoundSystem.EmitSoundDyn( self.edict(), CHAN_BODY, "turret/tu_deploy.wav", 0.5, ATTN_NORM, 0, 120 );
			}
			else if ( self.m_fSequenceFinished )
			{
				m_flLastSight = 0;
				SetSentryAnim( IDLE );
				SetThink( null );
				SetUse( UseFunction( TurretUse ) );
			}
		}
		else
		{
			SetSentryAnim( SPIN );
		}
	}
	
	// Put the sentry awake
	void Deploy()
	{
		self.pev.nextthink = g_Engine.time + 0.1;
		self.StudioFrameAdvance();
		
		// check here to play the sound only once
		if ( self.pev.sequence != GetSequence( DEPLOY ) )
		{
			SetSentryAnim( DEPLOY );
			
			g_SoundSystem.EmitSoundDyn( self.edict(), CHAN_BODY, "turret/tu_deploy.wav", 0.5, ATTN_NORM, 0, PITCH_NORM );
		}
		
		// when sequence finishes...
		if ( self.m_fSequenceFinished )
		{
			m_vecCurAngles.x = 0;
			m_vecCurAngles.y = Math.AngleMod( self.pev.angles.y );
			
			SetSentryAnim( SPIN );
			
			self.pev.framerate = 0;
			SetThink( ThinkFunction( SearchThink ) );
			
			if ( self.pev.SpawnFlagBitSet( SF_SENTRY_CANDISARM ) )
				SetUse( UseFunction( OpenDisarm ) );
		}
	}
	
	// Search for a new target
	void SearchThink()
	{
		// ensure rethink
		if ( m_iWeapon == W_MINIGUN && m_iWeaponState != STATE_OFF ) // firing? (or was preparing to fire)
		{
			// spin down
			SetSentryAnim( SPIN_DOWN );
			
			// wait until spin stops before attacking again
			m_iWeaponState = STATE_OFF;
			m_flNextFire = g_Engine.time + 1.0;
			g_SoundSystem.EmitSoundDyn( self.edict(), CHAN_WEAPON, "hassault/hw_spindown.wav", VOL_NORM, ATTN_NORM, 0, PITCH_NORM );
		}
		else
		{
			SetSentryAnim( SPIN );
			
			// don't spin the barrel!
			if ( m_iWeapon == W_MINIGUN )
				self.pev.framerate = 0;
		}
		self.StudioFrameAdvance();
		self.pev.nextthink = g_Engine.time + 0.1;
		
		Ping();
		
		// If we have a target and we're still healthy
		if ( self.m_hEnemy.IsValid() )
		{
			if ( !self.m_hEnemy.GetEntity().IsAlive() || self.m_hEnemy.GetEntity().pev.FlagBitSet( FL_NOTARGET ) )
				self.m_hEnemy = null; // Dead or untargetable enemy forces a search for new one
		}
		
		// Acquire Target
		if ( !self.m_hEnemy.IsValid() )
		{
			// If this is a healing sentry (has medkit) then only care for nearby allies
			if ( m_iWeapon == W_MEDKIT )
				self.m_hEnemy = BestVisibleAlly( GetRange() );
			else
			{
				self.Look( GetRange() );
				self.m_hEnemy = BestVisibleEnemy( GetRange() );
			}
		}
		
		// If we've found a target, start to attack
		if ( self.m_hEnemy.IsValid() )
		{
			SetThink( ThinkFunction( ActiveThink ) );
		}
		else
		{
			// generic hunt for new victims
			m_vecGoalAngles.y = ( m_vecGoalAngles.y + 0.1 * m_fTurnRate );
			if ( m_vecGoalAngles.y >= 360 )
				m_vecGoalAngles.y -= 360;
			MoveTurret();
		}
	}
	
	// Move sentry angles towards destination
	bool MoveTurret()
	{
		bool state = false;
		// any x movement?
		
		if ( m_vecCurAngles.x != m_vecGoalAngles.x )
		{
			float flDir = m_vecGoalAngles.x > m_vecCurAngles.x ? 1 : -1;
			
			m_vecCurAngles.x += 0.1 * m_fTurnRate * flDir;
			
			// if we started below the goal, and now we're past, peg to goal
			if ( flDir == 1 )
			{
				if ( m_vecCurAngles.x > m_vecGoalAngles.x )
					m_vecCurAngles.x = m_vecGoalAngles.x;
			}
			else
			{
				if ( m_vecCurAngles.x < m_vecGoalAngles.x )
					m_vecCurAngles.x = m_vecGoalAngles.x;
			}
			
			self.SetBoneController( 1, -m_vecCurAngles.x );
			state = true;
		}
		
		if ( m_vecCurAngles.y != m_vecGoalAngles.y )
		{
			float flDir = m_vecGoalAngles.y > m_vecCurAngles.y ? 1 : -1;
			float flDist = abs( m_vecGoalAngles.y - m_vecCurAngles.y );
			
			if ( flDist > 180 )
			{
				flDist = 360 - flDist;
				flDir = -flDir;
			}
			if ( flDist > 30 )
			{
				if ( m_fTurnRate < m_iBaseTurnRate * 10 )
				{
					m_fTurnRate += m_iBaseTurnRate;
				}
			}
			else if ( m_fTurnRate > 45 )
			{
				m_fTurnRate -= m_iBaseTurnRate;
			}
			else
			{
				m_fTurnRate += m_iBaseTurnRate;
			}
			
			m_vecCurAngles.y += 0.1 * m_fTurnRate * flDir;
			
			if ( m_vecCurAngles.y < 0 )
				m_vecCurAngles.y += 360;
			else if ( m_vecCurAngles.y >= 360 )
				m_vecCurAngles.y -= 360;
			
			if ( flDist < ( 0.05 * m_iBaseTurnRate ) )
				m_vecCurAngles.y = m_vecGoalAngles.y;
			
			self.SetBoneController( 0, m_vecCurAngles.y - self.pev.angles.y );
			state = true;
		}
		
		if ( !state )
			m_fTurnRate = m_iBaseTurnRate;
		
		return state;
	}
	
	// Attacking an enemy
	void ActiveThink()
	{
		bool fAttack = false;
		Vector vecDirToEnemy;
		
		self.pev.nextthink = g_Engine.time + 0.1;
		self.pev.framerate = 1;
		self.StudioFrameAdvance();
		
		if ( !self.m_hEnemy.IsValid() )
		{
			// enemy no longer exists, search for a new one
			self.m_hEnemy = null;
			m_flLastSight = 0;
			SetThink( ThinkFunction( SearchThink ) );
			
			CleanFireEffects();
			return;
		}
		
		// if it's dead (or no longer targeteable), look for something new
		if ( !self.m_hEnemy.GetEntity().IsAlive() || self.m_hEnemy.GetEntity().pev.FlagBitSet( FL_NOTARGET ) )
		{
			if ( m_flLastSight == 0 )
			{
				m_flLastSight = g_Engine.time + 0.5; // continue-shooting timeout
			}
			else
			{
				if ( g_Engine.time > m_flLastSight )
				{
					self.m_hEnemy = null;
					m_flLastSight = 0;
					SetThink( ThinkFunction( SearchThink ) );
					
					CleanFireEffects();
					return;
				}
			}
		}
		
		Vector vecMid = self.pev.origin + self.pev.view_ofs;
		Vector vecMidEnemy = self.m_hEnemy.GetEntity().BodyTarget( vecMid );
		
		// Look for our current enemy
		bool fEnemyVisible = self.pev.SpawnFlagBitSet( SF_SENTRY_IGNORE_LOS ) ? true : self.FVisible( self.m_hEnemy.GetEntity(), true );
		
		vecDirToEnemy = vecMidEnemy - vecMid; // calculate dir and dist to enemy
		float flDistToEnemy = vecDirToEnemy.Length();
		
		Vector vec = Math.VecToAngles( vecMidEnemy - vecMid );
		
		// Current enemy is not visible.
		if ( !fEnemyVisible || ( flDistToEnemy > GetRange() ) )
		{
			if ( m_flLastSight == 0 )
				m_flLastSight = g_Engine.time + 0.5;
			else
			{
				// Should we look for a new target?
				if ( g_Engine.time > m_flLastSight )
				{
					self.m_hEnemy = null;
					m_flLastSight = 0;
					SetThink( ThinkFunction( SearchThink ) );
					
					CleanFireEffects();
					return;
				}
			}
			fEnemyVisible = false;
		}
		else
		{
			m_vecLastSight = vecMidEnemy;
		}
		
		Math.MakeAimVectors( m_vecCurAngles );
		
		Vector vecLOS = vecDirToEnemy; //vecMid - m_vecLastSight;
		vecLOS = vecLOS.Normalize();
		
		float dot = DotProduct( vecLOS, g_Engine.v_forward );
		
		// Is the Gun looking at the target
		if ( m_iWeapon != W_GRAPPLE && dot <= 0.866 ) // 30 degree slop
			fAttack = false;
		else if ( m_iWeapon == W_GRAPPLE && dot <= 0.99 ) // for barnacle, either it's (almost) DIRECTLY aiming at the target or bust
			fAttack = false;
		else
			fAttack = true;
		
		// if the sentry is grappling something it will never let go
		// until its target dies or the sentry goes down in the attempt
		if ( m_iWeapon == W_GRAPPLE && m_pTip !is null && m_pTip.IsStuck() )
		{
			fAttack = true;
			fEnemyVisible = true;
		}
		
		// fire the gun
		if ( fAttack && g_Engine.time > m_flNextFire )
		{
			// minigun override
			if ( m_iWeapon == W_MINIGUN )
			{
				if ( m_iWeaponState == STATE_OFF ) // idle
				{
					// spin up
					SetSentryAnim( SPIN_UP );
					
					// prepare to fire
					m_iWeaponState = STATE_FIRING;
					m_flNextFire = g_Engine.time + 1.0;
					g_SoundSystem.EmitSoundDyn( self.edict(), CHAN_WEAPON, "hassault/hw_spinup.wav", VOL_NORM, ATTN_NORM, 0, PITCH_NORM );
					return;
				}
			}
			
			Vector vecSrc, vecAng;
			self.GetAttachment( 0, vecSrc, vecAng );
			
			if ( m_iWeapon > W_WRENCH )
			{
				// force it to fix muzzle
				SetSentryAnim( FIRE, true );
			}
			
			Shoot( vecSrc, g_Engine.v_forward );
		}
		else
		{
			if ( m_iWeapon != W_MINIGUN )
			{
				// don't change back the animation if we have an enemy (melee)
				if ( !self.m_hEnemy.IsValid() && ( m_iWeapon == W_CROWBAR || m_iWeapon == W_WRENCH ) )
				{
					SetSentryAnim( SPIN );
				}
				
				CleanFireEffects();
			}
		}
		
		//move the gun
		if ( fEnemyVisible )
		{
			if ( vec.y > 360 )
				vec.y -= 360;
			
			if ( vec.y < 0 )
				vec.y += 360;
			
			if ( vec.x < -180 )
				vec.x += 360;
			
			if ( vec.x > 180 )
				vec.x -= 360;
			
			// now all numbers should be in [1...360]
			// pin to turret limitations to [-90...15]
			
			if ( vec.x > 90 )
				vec.x = 90;
			else if ( vec.x < m_iMinPitch )
				vec.x = m_iMinPitch;
			
			m_vecGoalAngles.y = vec.y;
			m_vecGoalAngles.x = vec.x;
		}
		
		MoveTurret();
	}
	
	// Make the sentry fire its weapon
	void Shoot( Vector vecSrc, Vector vecDirToEnemy )
	{
		// TODO: ideally the firing spreads should match a real player weapon when it's
		// unmoving and standing. If devs are willing to give such info, that is... -Giegue
		switch ( m_iWeapon )
		{
			case W_GLOCK:
			{
				MyFireBullets( self, 1, vecSrc, vecDirToEnemy, VECTOR_CONE_1DEGREES, GetRange(), BULLET_PLAYER_9MM, 0 );
				g_SoundSystem.EmitSoundDyn( self.edict(), CHAN_WEAPON, "weapons/pl_gun3.wav", Math.RandomFloat( 0.92, 1.0 ), ATTN_NORM, 0, 98 + Math.RandomLong( 0, 3 ) );
				
				m_flNextFire = g_Engine.time + 0.3;
				break;
			}
			case W_PYTHON:
			{
				MyFireBullets( self, 1, vecSrc, vecDirToEnemy, VECTOR_CONE_4DEGREES, GetRange(), BULLET_PLAYER_357, 0 );
				g_SoundSystem.EmitSoundDyn( self.edict(), CHAN_WEAPON, "weapons/357_shot1.wav", Math.RandomFloat( 0.8, 0.9 ), ATTN_NORM, 0, PITCH_NORM );
				
				m_flNextFire = g_Engine.time + 0.75;
				break;
			}
			case W_DESERT_EAGLE:
			{
				MyFireBullets( self, 1, vecSrc, vecDirToEnemy, VECTOR_CONE_2DEGREES, GetRange(), BULLET_PLAYER_EAGLE, 0 );
				g_SoundSystem.EmitSoundDyn( self.edict(), CHAN_WEAPON, "weapons/de_shot1.wav", Math.RandomFloat( 0.92, 1.0 ), ATTN_NORM, 0, 98 + Math.RandomLong( 0, 3 ) );
				
				m_flNextFire = g_Engine.time + 0.6;
				break;
			}
			case W_MP5:
			{
				MyFireBullets( self, 1, vecSrc, vecDirToEnemy, VECTOR_CONE_3DEGREES, GetRange(), BULLET_PLAYER_MP5, 0 );
				g_SoundSystem.EmitSoundDyn( self.edict(), CHAN_WEAPON, "weapons/hks1.wav", VOL_NORM, ATTN_NORM, 0, 94 + Math.RandomLong( 0, 0xF ) );
				
				//m_flNextFire = g_Engine.time + 0.1;
				break;
			}
			case W_UZI:
			{
				MyFireBullets( self, 1, vecSrc, vecDirToEnemy, VECTOR_CONE_4DEGREES, GetRange(), BULLET_PLAYER_CUSTOMDAMAGE, int( g_EngineFuncs.CVarGetFloat( "sk_plr_uzi" ) ) );
				g_SoundSystem.EmitSoundDyn( self.edict(), CHAN_WEAPON, "weapons/uzi/shoot1.wav", VOL_NORM, ATTN_NORM, 0, 94 + Math.RandomLong( 0, 0xF ) );
				
				//m_flNextFire = g_Engine.time + 0.1;
				break;
			}
			case W_UZIAKIMBO:
			{
				MyFireBullets( self, 2, vecSrc, vecDirToEnemy, VECTOR_CONE_5DEGREES, GetRange(), BULLET_PLAYER_CUSTOMDAMAGE, int( g_EngineFuncs.CVarGetFloat( "sk_plr_uzi" ) ) );
				g_SoundSystem.EmitSoundDyn( self.edict(), CHAN_WEAPON, "weapons/uzi/fire_both1.wav", VOL_NORM, ATTN_NORM, 0, 94 + Math.RandomLong( 0, 0xF ) );
				
				//m_flNextFire = g_Engine.time + 0.1;
				break;
			}
			case W_SHOTGUN:
			{
				MyFireBullets( self, 8, vecSrc, vecDirToEnemy, VECTOR_CONE_10DEGREES, GetRange(), BULLET_PLAYER_BUCKSHOT, 0 );
				g_SoundSystem.EmitSoundDyn( self.edict(), CHAN_WEAPON, "weapons/sbarrel1.wav", Math.RandomFloat( 0.95, 1.0 ), ATTN_NORM, 0, 93 + Math.RandomLong( 0, 0x1F ) );
				
				m_flNextFire = g_Engine.time + 0.75;
				break;
			}
			case W_CROSSBOW:
			{
				CBaseEntity@ pDart = g_EntityFuncs.Create( "crossbow_bolt", vecSrc, m_vecCurAngles, false, self.edict() );
				pDart.pev.velocity = vecDirToEnemy * 2000;
				
				g_SoundSystem.EmitSoundDyn( self.edict(), CHAN_WEAPON, "weapons/xbow_fire1.wav", VOL_NORM, ATTN_NORM, 0, 93 + Math.RandomLong( 0, 0xF ) );
				
				m_flNextFire = g_Engine.time + 0.75;
				break;
			}
			case W_HORNETGUN:
			{
				CBaseEntity@ pHornet = null;
				
				// use player variant if ally
				if ( self.IsPlayerAlly() )
					@pHornet = g_EntityFuncs.Create( "playerhornet", vecSrc + g_Engine.v_up * -2, m_vecCurAngles, false, self.edict() );
				else
					@pHornet = g_EntityFuncs.Create( "hornet", vecSrc + g_Engine.v_up * -2, m_vecCurAngles, false, self.edict() );
				
				pHornet.pev.velocity = vecDirToEnemy * 300;
				
				switch ( Math.RandomLong( 0, 2 ) )
				{
					case 0: g_SoundSystem.EmitSoundDyn( self.edict(), CHAN_WEAPON, "agrunt/ag_fire1.wav", VOL_NORM, ATTN_NORM, 0, PITCH_NORM ); break;
					case 1: g_SoundSystem.EmitSoundDyn( self.edict(), CHAN_WEAPON, "agrunt/ag_fire2.wav", VOL_NORM, ATTN_NORM, 0, PITCH_NORM ); break;
					case 2: g_SoundSystem.EmitSoundDyn( self.edict(), CHAN_WEAPON, "agrunt/ag_fire3.wav", VOL_NORM, ATTN_NORM, 0, PITCH_NORM ); break;
				}
				
				// copy the turret's enemy to the hornet
				cast< CBaseMonster@ >( pHornet ).m_hEnemy = self.m_hEnemy;
				
				m_flNextFire = g_Engine.time + 0.25;
				break;
			}
			case W_M16:
			{
				MyFireBullets( self, 1, vecSrc, vecDirToEnemy, VECTOR_CONE_3DEGREES, GetRange(), BULLET_PLAYER_SAW, 0 );
				
				// first bullet emits sound
				if ( m_iClip == 3 )
					g_SoundSystem.EmitSoundDyn( self.edict(), CHAN_WEAPON, "weapons/m16_3round.wav", VOL_NORM, ATTN_NORM, 0, 99 + Math.RandomLong( 0, 2 ) );
				
				m_iClip--;
				if ( m_iClip <= 0 )
				{
					// reload
					m_flNextFire = g_Engine.time + 0.25;
					m_iClip = 3;
				}
				break;
			}
			case W_M249:
			{
				MyFireBullets( self, 1, vecSrc, vecDirToEnemy, VECTOR_CONE_4DEGREES, GetRange(), BULLET_PLAYER_SAW, 0 );
				g_SoundSystem.EmitSoundDyn( self.edict(), CHAN_WEAPON, "weapons/saw_fire1.wav", VOL_NORM, ATTN_NORM, 0, 94 + Math.RandomLong( 0, 0xF ) );
				
				//m_flNextFire = g_Engine.time + 0.1;
				break;
			}
			case W_SNIPERRIFLE:
			{
				MyFireBullets( self, 1, vecSrc, vecDirToEnemy, VECTOR_CONE_1DEGREES, GetRange(), BULLET_PLAYER_SNIPER, 0 );
				g_SoundSystem.EmitSoundDyn( self.edict(), CHAN_WEAPON, "weapons/sniper_fire.wav", Math.RandomFloat( 0.8, 0.9 ), ATTN_NORM, 0, 99 + Math.RandomLong( 0, 2 ) );
				
				m_flNextFire = g_Engine.time + 2.0;
				break;
			}
			case W_DISPLACER:
			{
				g_EntityFuncs.CreateDisplacerPortal( vecSrc, vecDirToEnemy * 500, self.edict(), g_EngineFuncs.CVarGetFloat( "sk_plr_displacer_other" ), g_EngineFuncs.CVarGetFloat( "sk_plr_displacer_radius" ) );
				g_SoundSystem.EmitSoundDyn( self.edict(), CHAN_WEAPON, "weapons/displacer_fire.wav", VOL_NORM, ATTN_NORM, 0, PITCH_NORM );
				
				m_flNextFire = g_Engine.time + 2.0;
				break;
			}
			case W_RPG:
			{
				if ( m_iWeaponState == STATE_OFF )
				{
					// prepare
					m_flNextFire = g_Engine.time + 1.0;
					m_iWeaponState = STATE_FIRING;
					self.pev.body += B_RPG;
					
					// ping now
					m_flPingTime = g_Engine.time;
					Ping();
				}
				else
				{
					// fire
					g_EntityFuncs.CreateRPGRocket( vecSrc, m_vecCurAngles, self.edict() );
					g_SoundSystem.EmitSoundDyn( self.edict(), CHAN_WEAPON, "weapons/rocketfire1.wav", VOL_NORM, ATTN_NORM, 0, PITCH_NORM );
					
					m_flNextFire = g_Engine.time + 2.0;
					m_iWeaponState = STATE_OFF;
					self.pev.body -= B_RPG;
				}
				break;
			}
			case W_SHOCKRIFLE:
			{
				CBaseEntity@ pShock = g_EntityFuncs.Create( "shock_beam", vecSrc, m_vecCurAngles, false, self.edict() );
				pShock.pev.velocity = vecDirToEnemy * 1500;
				
				g_SoundSystem.EmitSoundDyn( self.edict(), CHAN_WEAPON, "weapons/shock_fire.wav", VOL_NORM, ATTN_NORM, 0, PITCH_NORM );
				
				m_flNextFire = g_Engine.time + 0.2;
				break;
			}
			case W_SPORELAUNCHER:
			{
				// HACK - CEntityFuncs does not have any function to create a spore grenade,
				// and creating a "sporegrenade" entity "as-is" does not work as intended.
				// Luckily - "ammo_spore" is always precached, so we can create a temporary,
				// ammo_spore to act as a "launcher", force it to launch the spore,
				// then remove the temporary entity. Hurray for workarounds! -Giegue
				
				CBaseEntity@ pLauncher = g_EntityFuncs.Create( "ammo_spore", vecSrc + vecDirToEnemy * 17, m_vecCurAngles, false, self.edict() );
				pLauncher.pev.angles.y -= 180; // direction fix
				pLauncher.pev.effects = EF_NODRAW; // don't be seen
				pLauncher.pev.body = 1; // so it can start shooting right away
				pLauncher.TakeDamage( pLauncher.pev, pLauncher.pev, 1.0, DMG_GENERIC ); // "damage" it to launch it
				g_EntityFuncs.Remove( pLauncher );
				
				// ammo_spore emits its own sound
				//g_SoundSystem.EmitSoundDyn( self.edict(), CHAN_WEAPON, "weapons/splauncher_altfire.wav", VOL_NORM, ATTN_NORM, 0, PITCH_NORM );
				
				// Another HACK - The launched spore will hurt anything in its way, be it
				// ally or enemy. The spore should remember its owner classification
				// to avoid hurting its allies. CEntityFuncs::Remove only sets FL_KILLME
				// instead of instantly removing it, meaning we have 1 frame to find
				// the owner of the launched spore. Which is just enough time for us to
				// copy the owner classification to the appropiate entity.
				// (There can be more than one active spore!) -Giegue
				
				CBaseMonster@ pSpore = null;
				// start from the newly created launcher
				while ( ( @pSpore = cast< CBaseMonster@ >( g_EntityFuncs.FindEntityByClassname( pSpore is null ? pLauncher : pSpore, "sporegrenade" ) ) ) !is null )
				{
					if ( pSpore.pev.owner is pLauncher.edict() )
					{
						// this is the spore that we should make aware of
						@pSpore.pev.owner = self.edict(); // point back to turret
						pSpore.SetClassificationFromEntity( self ); // copy classify, do not hurt allies
						break;
					}
				}
				
				m_flNextFire = g_Engine.time + 0.6;
				break;
			}
			case W_EGON: // Perhaps code might look cleaner if these fire stuff were moved to their own functions... -Giegue
			{
				// CEgon::Attack
				if ( m_iWeaponState == STATE_OFF )
				{
					g_SoundSystem.EmitSoundDyn( self.edict(), CHAN_WEAPON, "weapons/egon_windup2.wav", VOL_NORM, ATTN_NORM, 0, 125 );
					
					self.pev.fuser1 = g_Engine.time + 2; // change sound after 2 seconds
					self.pev.fuser2 = 0; // can shake screen as soon as it fires
					
					m_iWeaponState = STATE_FIRING;
				}
				else
				{
					// sound.wav
					if ( self.pev.fuser1 <= g_Engine.time )
					{
						g_SoundSystem.EmitSoundDyn( self.edict(), CHAN_WEAPON, "weapons/egon_run3.wav", VOL_NORM, ATTN_NORM, 0, 125 );
						self.pev.fuser1 = 1000;
					}
					
					// CEgon::Fire
					Vector vecDest = vecSrc + vecDirToEnemy * 2048;
					TraceResult tr;
					
					Vector tmpSrc = vecSrc + g_Engine.v_up * -8 + g_Engine.v_right * 3;
					
					g_Utility.TraceLine( vecSrc, vecDest, dont_ignore_monsters, self.edict(), tr );
					
					if ( tr.fAllSolid > 0 )
						return;
					
					CBaseEntity@ pEntity = g_EntityFuncs.Instance( tr.pHit );
					
					if ( pEntity is null )
						return;
					
					if ( m_pSprite !is null && pEntity.pev.takedamage > DAMAGE_NO )
					{
						m_pSprite.pev.effects &= ~EF_NODRAW;
					}
					else if ( m_pSprite !is null )
					{
						m_pSprite.pev.effects |= EF_NODRAW;
					}
					
					float timedist;
					int iDamage = int( g_EngineFuncs.CVarGetFloat( "sk_plr_egon_wide" ) );
					
					// FIRE_WIDE:
					g_WeaponFuncs.ClearMultiDamage();
					if ( pEntity.pev.takedamage > DAMAGE_NO )
					{
						pEntity.TraceAttack( self.pev, iDamage, vecDirToEnemy, tr, ( DMG_ENERGYBEAM | DMG_ALWAYSGIB ) );
					}
					g_WeaponFuncs.ApplyMultiDamage( self.pev, self.pev );
					g_WeaponFuncs.RadiusDamage( tr.vecEndPos, self.pev, self.pev, ( iDamage / 4 ), 128, Classify(), ( DMG_ENERGYBEAM | DMG_BLAST | DMG_ALWAYSGIB ) );
					
					if ( !self.IsAlive() )
						return;
					
					if ( self.pev.fuser2 < g_Engine.time )
					{
						g_PlayerFuncs.ScreenShake( tr.vecEndPos, 5.0, 150.0, 0.75, 250.0 );
						self.pev.fuser2 = g_Engine.time + 1.5;
					}
					
					timedist = ( self.pev.fuser3 - g_Engine.time ) / 0.1;
					
					if ( timedist < 0 )
						timedist = 0;
					else if ( timedist > 1 )
						timedist = 1;
					timedist = 1 - timedist;
					
					EgonUpdate( tmpSrc, tr.vecEndPos, timedist );
				}
				break;
			}
			case W_GAUSS:
			{
				//CGauss::Fire
				Vector vecDest = vecSrc + vecDirToEnemy * 8192;
				
				TraceResult tr;
				edict_t@ pentIgnore = self.edict();
				
				float flMaxFrac = 1.0;
				float flDamage = g_EngineFuncs.CVarGetFloat( "sk_plr_gauss" ); // primary gauss attack
				
				int nMaxHits = 10;
				
				g_SoundSystem.EmitSoundDyn( self.edict(), CHAN_WEAPON, "weapons/gauss2.wav", VOL_NORM, ATTN_NORM, 0, 95 + Math.RandomLong( 0, 0xF ) );
				
				g_Utility.TraceLine( vecSrc, vecDest, dont_ignore_monsters, pentIgnore, tr );
				
				uint8 r, g, b, a, Z_h;
				r = 250;
				g = 200;
				b = 10;
				Z_h = 9;
				a = 250;
				
				// Ugly, but it will do. -Giegue
				BeamEffect( vecSrc, tr.vecEndPos, Z_h, r, g, b, a ); // beam 1
				
				while ( flDamage > 10 && nMaxHits > 0 )
				{
					nMaxHits--;
					
					g_Utility.TraceLine( vecSrc, vecDest, dont_ignore_monsters, pentIgnore, tr );
					
					if ( tr.fAllSolid > 0 )
						break;
					
					CBaseEntity@ pEntity = g_EntityFuncs.Instance( tr.pHit );
					
					if ( pEntity is null )
						break;
					
					if ( pEntity.pev.takedamage > DAMAGE_NO )
					{
						g_WeaponFuncs.ClearMultiDamage();
						pEntity.TraceAttack( self.pev, flDamage, vecDirToEnemy, tr, DMG_BULLET );
						g_WeaponFuncs.ApplyMultiDamage( self.pev, self.pev );
					}
					
					if ( pEntity.ReflectGauss() )
					{
						float Z_n;
						
						@pentIgnore = null;
						
						Z_n = -( DotProduct( tr.vecPlaneNormal, vecDirToEnemy ) );
						
						if ( Z_n < 0.5 ) // 60 degrees
						{
							// reflect
							Vector Z_r;
							
							Z_r = 2.0 * tr.vecPlaneNormal * Z_n + vecDirToEnemy;
							flMaxFrac = flMaxFrac - tr.flFraction;
							vecDirToEnemy = Z_r;
							vecSrc = tr.vecEndPos + vecDirToEnemy * 8;
							vecDest = vecSrc + vecDirToEnemy * 8192;
							
							// explode a bit
							g_WeaponFuncs.RadiusDamage( tr.vecEndPos, self.pev, self.pev, flDamage * Z_n, flDamage * 1.75, Classify(), DMG_BLAST );
							
							// lose energy
							if ( Z_n == 0 ) Z_n = 0.1;
							flDamage = flDamage * ( 1 - Z_n );
							
							// beam 2
							BeamEffect( vecSrc, vecDest, Z_h, r, g, b, a );
						}
					}
					else
					{
						vecSrc = tr.vecEndPos + vecDirToEnemy;
						@pentIgnore = pEntity.edict();
					}
				}
				
				m_flNextFire = g_Engine.time + 0.2;
				break;
			}
			case W_MINIGUN:
			{
				MyFireBullets( self, 1, vecSrc, vecDirToEnemy, VECTOR_CONE_6DEGREES, GetRange(), BULLET_PLAYER_SAW, 0 );
				g_SoundSystem.EmitSoundDyn( self.edict(), CHAN_WEAPON, "minigun/hw_shoot1.wav", VOL_NORM, ATTN_NORM, 0, PITCH_NORM );
				m_iWeaponState = STATE_READY;
				
				//m_flNextFire = g_Engine.time + 0.1;
				self.pev.nextthink = g_Engine.time + 0.08;
				break;
			}
			case W_CROWBAR: // 32 is the player range but it doesn't fit the model very well
			{
				CBaseEntity@ pTarget = CheckTraceHullAttack( 32, int( g_EngineFuncs.CVarGetFloat( "sk_plr_crowbar" ) ), DMG_SLASH );
				if ( pTarget !is null )
				{
					// force-reset animation
					SetSentryAnim( FIRE, true );
					
					// sound
					switch( Math.RandomLong( 0, 2 ) )
					{
						case 0: g_SoundSystem.EmitSoundDyn( self.edict(), CHAN_WEAPON, "weapons/cbar_hitbod1.wav", VOL_NORM, ATTN_NORM, 0, PITCH_NORM ); break;
						case 1: g_SoundSystem.EmitSoundDyn( self.edict(), CHAN_WEAPON, "weapons/cbar_hitbod2.wav", VOL_NORM, ATTN_NORM, 0, PITCH_NORM ); break;
						case 2: g_SoundSystem.EmitSoundDyn( self.edict(), CHAN_WEAPON, "weapons/cbar_hitbod3.wav", VOL_NORM, ATTN_NORM, 0, PITCH_NORM ); break;
					}
					
					m_flNextFire = g_Engine.time + 0.3;
				}
				
				break;
			}
			case W_WRENCH:
			{
				CBaseEntity@ pTarget = CheckTraceHullAttack( 32, int( g_EngineFuncs.CVarGetFloat( "sk_plr_wrench" ) ), DMG_SLASH );
				if ( pTarget !is null )
				{
					// force-reset animation
					SetSentryAnim( FIRE, true );
					self.pev.framerate = 1.25; // anim is too slow, try to match attack rate
					
					// sound
					switch( Math.RandomLong( 0, 2 ) )
					{
						case 0: g_SoundSystem.EmitSoundDyn( self.edict(), CHAN_WEAPON, "weapons/pwrench_hitbod1.wav", VOL_NORM, ATTN_NORM, 0, PITCH_NORM ); break;
						case 1: g_SoundSystem.EmitSoundDyn( self.edict(), CHAN_WEAPON, "weapons/pwrench_hitbod2.wav", VOL_NORM, ATTN_NORM, 0, PITCH_NORM ); break;
						case 2: g_SoundSystem.EmitSoundDyn( self.edict(), CHAN_WEAPON, "weapons/pwrench_hitbod3.wav", VOL_NORM, ATTN_NORM, 0, PITCH_NORM ); break;
					}
					
					m_flNextFire = g_Engine.time + 0.5;
				}
				
				break;
			}
			case W_MEDKIT:
			{
				CBaseEntity@ pTarget = CheckTraceHullAttack( 32, int( -g_EngineFuncs.CVarGetFloat( "sk_plr_hpMedic" ) ), DMG_MEDKITHEAL );
				if ( pTarget !is null )
				{
					// sound
					g_SoundSystem.EmitSoundDyn( self.edict(), CHAN_WEAPON, "items/medshot5.wav", VOL_NORM, ATTN_IDLE, 0, PITCH_NORM );
					m_flNextFire = g_Engine.time + 0.5;
				}
				
				break;
			}
			case W_GRAPPLE: // ho boi... here we go
			{
				// CGrapple::PrimaryAttack
				if ( m_pTip !is null )
				{
					if ( m_pTip.IsStuck() )
					{
						CBaseEntity@ pTarget = m_pTip.GetGrappleTarget();
						
						if ( pTarget is null )
						{
							GrappleEnd();
							m_flNextFire = g_Engine.time + 0.5;
							return;
						}
						
						if ( pTarget !is self.m_hEnemy.GetEntity() )
						{
							// The grapple grabbed something different than its target
							self.m_hEnemy = pTarget;
						}
						
						self.pev.movetype = MOVETYPE_FLY;
						g_EntityFuncs.SetOrigin( m_pTip.self, pTarget.Center() );
						
						if ( m_pTip.ShouldPushTarget() )
						{
							// Small target, push towards sentry
							pTarget.pev.velocity = pTarget.pev.velocity + ( vecSrc - pTarget.pev.origin );
							if ( pTarget.pev.velocity.Length() > 450.0 )
								pTarget.pev.velocity = pTarget.pev.velocity.Normalize() * 450.0;
						}
						else
						{
							// Big target, move towards enemy
							self.pev.velocity = self.pev.velocity + ( m_pTip.pev.origin - ( vecSrc + Vector( 0, 0, -16 ) ) ); // to lift the sentry off the ground
							if (self.pev.velocity.Length() > 450.0 )
								self.pev.velocity = self.pev.velocity.Normalize() * 450.0;
						}
					}
					
					if ( m_pTip.HasMissed() )
					{
						g_SoundSystem.EmitSoundDyn( self.edict(), CHAN_STATIC, "weapons/bgrapple_release.wav", 0.98, ATTN_NORM, 0, 125 );
						
						GrappleEnd();
						m_flNextFire = g_Engine.time + 0.5;
						return;
					}
				}
				
				if ( m_iWeaponState == STATE_OFF )
				{
					g_SoundSystem.EmitSoundDyn( self.edict(), CHAN_WEAPON, "weapons/bgrapple_fire.wav", 0.98, ATTN_NORM, 0, 125 );
					m_iWeaponState = STATE_FIRING;
				}
				else
				{
					if ( self.pev.fuser1 != 1000 )
					{
						// CGrapple::Fire
						Vector vecEnd = vecSrc + vecDirToEnemy * 2048.0;
						
						TraceResult tr;
						g_Utility.TraceLine( vecSrc, vecEnd, dont_ignore_monsters, self.edict(), tr );
						
						if ( tr.fAllSolid == 0 )
						{
							GrappleUpdate( vecSrc );
							self.pev.fuser2 = g_Engine.time;
						}
						
						g_SoundSystem.EmitSoundDyn( self.edict(), CHAN_STATIC, "weapons/bgrapple_pull.wav", 0.98, ATTN_NORM, 0, 115 );
						self.pev.fuser1 = 1000;
					}
				}
				
				if ( m_pTip is null )
				{
					self.pev.nextthink = g_Engine.time + 0.01;
					return;
				}
				
				if ( m_pTip.IsStuck() )
				{
					Math.MakeVectors( m_vecCurAngles );
					
					Vector vecEnd = vecSrc + g_Engine.v_forward * 16.0;
					
					TraceResult tr;
					g_Utility.TraceLine( vecSrc, vecEnd, dont_ignore_monsters, self.edict(), tr );
					
					if ( tr.flFraction >= 1.0 )
					{
						g_Utility.TraceHull( vecSrc, vecEnd, dont_ignore_monsters, head_hull, self.edict(), tr );
						
						if ( tr.flFraction < 1.0 )
						{
							// If we've hit a solid object see if we're hurting it
							if ( tr.pHit is null || FNullEnt( tr.pHit ) || g_EntityFuncs.Instance( tr.pHit ).IsBSPModel() )
							{
								g_Utility.FindHullIntersection( vecSrc, tr, tr, VEC_DUCK_HULL_MIN, VEC_DUCK_HULL_MAX, self.edict() );
							}
						}
					}
					
					if ( tr.flFraction < 1.0 )
					{
						CBaseEntity@ pHit = g_EntityFuncs.Instance( tr.pHit );
						
						if ( pHit !is null )
						{
							// The grapple might hit something like a wall while it's traveling.
							// Technically, it should not be able to hurt brush entities...
							// But I'm leaving it for the lulz.
							if ( self.pev.fuser2 + 0.5 < g_Engine.time )
							{
								g_WeaponFuncs.ClearMultiDamage();
								
								float flDamage = g_EngineFuncs.CVarGetFloat( "sk_plr_grapple" );
								pHit.TraceAttack( self.pev, flDamage, g_Engine.v_forward, tr, DMG_ALWAYSGIB | DMG_CLUB );
								
								g_WeaponFuncs.ApplyMultiDamage( self.pev, self.pev );
								
								self.pev.fuser2 = g_Engine.time;
								
								switch( Math.RandomLong( 0, 2 ) )
								{
									case 0: g_SoundSystem.EmitSoundDyn( self.edict(), CHAN_VOICE, "barnacle/bcl_chew1.wav", VOL_NORM, ATTN_NORM, 0, 115 ); break;
									case 1: g_SoundSystem.EmitSoundDyn( self.edict(), CHAN_VOICE, "barnacle/bcl_chew2.wav", VOL_NORM, ATTN_NORM, 0, 115 ); break;
									case 2: g_SoundSystem.EmitSoundDyn( self.edict(), CHAN_VOICE, "barnacle/bcl_chew3.wav", VOL_NORM, ATTN_NORM, 0, 115 ); break;
								}
							}
						}
					}
				}
				
				self.pev.nextthink = g_Engine.time + 0.01;
				break;
			}
		}
		
		// only do muzzle for these weapons
		if ( m_iWeapon > W_GRAPPLE && m_iWeapon != W_SPORELAUNCHER )
			self.pev.effects |= EF_MUZZLEFLASH;
	}
	
	// Handles damage taken to the sentry
	int TakeDamage( entvars_t@ pevInflictor, entvars_t@ pevAttacker, float flDamage, int bitsDamageType )
	{
		CBaseEntity@ pAttacker = g_EntityFuncs.Instance( pevAttacker );
		if ( pAttacker !is null && self.IRelationship( pAttacker ) == R_AL ) // ally trying to damage this?
		{
			if ( pAttacker.IsPlayer() )
			{
				CBasePlayer@ pPlayer = cast< CBasePlayer@ >( pAttacker );
				
				// It's a player. Using the wrench?
				CBasePlayerWeapon@ pWeapon = cast< CBasePlayerWeapon@ >( pPlayer.m_hActiveItem.GetEntity() );
				if ( pWeapon !is null && pWeapon.m_iId == WEAPON_PIPEWRENCH )
				{
					// It should be alive
					if ( self.IsAlive() )
					{
						// Calculate how much HP are we going to heal
						float flHeal = flDamage;
						if ( ( self.pev.health + flHeal ) > self.pev.max_health )
							flHeal = self.pev.max_health - self.pev.health;
						
						self.TakeHealth( flHeal, DMG_MEDKITHEAL );
						
						// If there is any healing, emit sound
						if ( flHeal > 0.0 )
						{
							switch ( Math.RandomLong( 0, 1 ) )
							{
								// TODO: get proper pitch
								case 0: g_SoundSystem.EmitSoundDyn( self.edict(), CHAN_BODY, "weapons/cbar_hit1.wav", VOL_NORM, ATTN_NORM, 0, 160 ); break;
								case 1: g_SoundSystem.EmitSoundDyn( self.edict(), CHAN_BODY, "weapons/cbar_hit2.wav", VOL_NORM, ATTN_NORM, 0, 160 ); break;
							}
						}
					}
					
					return 0;
				}
			}
			
			if ( g_EngineFuncs.CVarGetFloat( "mp_npckill" ) == 2 )
				return 0; // allies can't hurt this turret
		}
		
		if ( self.pev.takedamage == DAMAGE_NO )
			return 0;
		
		self.pev.health -= flDamage;
		if ( self.pev.health <= 0 )
		{
			self.pev.health = 0;
			self.pev.takedamage = DAMAGE_NO;
			self.pev.dmgtime = g_Engine.time;
			
			self.pev.flags &= ~FL_MONSTER;
			
			SetUse( null );
			SetThink( ThinkFunction( SentryDeath ) );
			self.pev.nextthink = g_Engine.time + 0.1;
			
			return 0;
		}
		
		// award score to attacker
		if ( pAttacker !is null )
		{
			// does not work, go manual
			//pAttacker.GetPointsForDamage( flDamage );
			
			// for every 40 damage dealt, add 1 point
			pAttacker.pev.frags += ( flDamage / 40.0 );
		}
		
		// wake up
		if ( !self.IsPlayerAlly() && self.pev.SpawnFlagBitSet( SF_SENTRY_STARTDAMAGE ) && self.pev.sequence == GetSequence( IDLE ) )
		{
			self.pev.nextthink = g_Engine.time + 0.1;
			SetThink( ThinkFunction( Deploy ) );
			SetUse( null );
		}
		
		return 1;
	}
	
	// Sentry is dying
	void SentryDeath()
	{
		self.FCheckAITrigger();
		
		self.StudioFrameAdvance();
		self.pev.nextthink = g_Engine.time + 0.1;
		
		if ( self.pev.deadflag != DEAD_DEAD )
		{
			self.pev.deadflag = DEAD_DEAD;
			
			float flRndSound = Math.RandomFloat( 0, 1 );
			
			if ( flRndSound <= 0.33 )
				g_SoundSystem.EmitSoundDyn( self.edict(), CHAN_BODY, "turret/tu_die.wav", VOL_NORM, ATTN_NORM, 0, PITCH_NORM );
			else if ( flRndSound <= 0.66 )
				g_SoundSystem.EmitSoundDyn( self.edict(), CHAN_BODY, "turret/tu_die2.wav", VOL_NORM, ATTN_NORM, 0, PITCH_NORM );
			else
				g_SoundSystem.EmitSoundDyn( self.edict(), CHAN_BODY, "turret/tu_die3.wav", VOL_NORM, ATTN_NORM, 0, PITCH_NORM );
			
			g_SoundSystem.EmitSoundDyn( self.edict(), CHAN_STATIC, "turret/tu_active2.wav", 0, 0, SND_STOP, PITCH_NORM );
			
			self.SetBoneController( 0, 0 );
			self.SetBoneController( 1, 0 );
			
			SetSentryAnim( DIE );
			
			self.pev.solid = SOLID_NOT;
			self.pev.angles.y = Math.AngleMod( self.pev.angles.y + Math.RandomLong( 0, 2 ) * 120 );
			
			CleanFireEffects();
		}
		
		Vector vecSrc, vecAng;
		self.GetAttachment( 1, vecSrc, vecAng );
		
		if ( self.pev.dmgtime + Math.RandomFloat( 0, 2 ) > g_Engine.time )
		{
			// lots of smoke
			NetworkMessage smoke( MSG_BROADCAST, NetworkMessages::SVC_TEMPENTITY );
			smoke.WriteByte( TE_SMOKE );
			smoke.WriteCoord( vecSrc.x + Math.RandomFloat( -16, 16 ) );
			smoke.WriteCoord( vecSrc.y + Math.RandomFloat( -16, 16 ) );
			smoke.WriteCoord( vecSrc.z - 32 );
			smoke.WriteShort( m_Smoke );
			smoke.WriteByte( 15 ); // scale * 10
			smoke.WriteByte( 8 ); // framerate
			smoke.End();
		}
		
		if ( self.pev.dmgtime + Math.RandomFloat( 0, 8 ) > g_Engine.time)
		{
			g_Utility.Sparks( vecSrc );
		}
		
		if ( self.m_fSequenceFinished && self.pev.dmgtime + 5 < g_Engine.time )
		{
			self.pev.framerate = 0;
			Explode();
		}
	}
	
	// Explosion!
	void Explode()
	{
		// Position
		Vector vecSpot = self.pev.origin + ( self.pev.mins + self.pev.maxs ) * 0.5;
		
		// Actual explosion
		g_EntityFuncs.CreateExplosion( vecSpot, g_vecZero, null, 50, true );
		
		// Wreckage
		NetworkMessage wreck( MSG_PVS, NetworkMessages::SVC_TEMPENTITY, vecSpot );
		wreck.WriteByte( TE_BREAKMODEL );
		wreck.WriteCoord( vecSpot.x ); // position
		wreck.WriteCoord( vecSpot.y );
		wreck.WriteCoord( vecSpot.z );
		wreck.WriteCoord( 64 ); // size
		wreck.WriteCoord( 64 );
		wreck.WriteCoord( 8 );
		wreck.WriteCoord( 0 ); // velocity
		wreck.WriteCoord( 0 );
		wreck.WriteCoord( 30 );
		wreck.WriteByte( 10 ); // randomization
		wreck.WriteShort( m_BodyGibs ); // model
		wreck.WriteByte( 25 ); // number of shards
		wreck.WriteByte( 100 ); // duration in 0.05 s
		wreck.WriteByte( BREAK_METAL ); // flags
		wreck.End();
		
		// Sentry is truly, ded.
		g_EntityFuncs.Remove( self );
	}
	
	// tu_ping.wav
	void Ping()
	{
		// make the pinging noise every second while searching
		if ( m_flPingTime == 0 )
			m_flPingTime = g_Engine.time + 1;
		else if ( m_flPingTime <= g_Engine.time )
		{
			m_flPingTime = g_Engine.time + 1;
			g_SoundSystem.EmitSoundDyn( self.edict(), CHAN_ITEM, "turret/tu_ping.wav", VOL_NORM, ATTN_NORM, 0, PITCH_NORM );
		}
	}
	
	// Change turret sequence
	void SetSentryAnim( int sequence, bool force = false )
	{
		if ( force || self.pev.sequence != GetSequence( sequence ) )
		{
			self.pev.sequence = GetSequence( sequence );
			self.pev.frame = 0;
			self.ResetSequenceInfo();
		}
	}
	
	// Select proper animation sequence
	int GetSequence( int sequence )
	{
		int anim = sequence;
		switch ( sequence )
		{
			case IDLE:
			{
				if ( m_iWeapon <= W_DESERT_EAGLE )
					anim = 0;
				else
					anim = 9;
				break;
			}
			case FIRE:
			{
				// save for minigun, it's one after another
				if ( m_iWeapon == W_MINIGUN )
					anim = 41;
				else
					anim = m_iWeapon + 14;
				break;
			}
			case SPIN:
			{
				// unique spin animations for crowbar/wrench only
				if ( m_iWeapon == W_CROWBAR || m_iWeapon == W_WRENCH )
					anim = 17;
				else
					anim = 2;
				break;
			}
			case DEPLOY:
			{
				// unique deploy animations for crowbar/wrench only
				if ( m_iWeapon == W_CROWBAR || m_iWeapon == W_WRENCH )
					anim = 16;
				else if ( m_iWeapon <= W_DESERT_EAGLE )
					anim = 3;
				else
					anim = 10;
				break;
			}
			case RETIRE:
			{
				// melee weapons do not have a retire variant!
				if ( m_iWeapon <= W_DESERT_EAGLE )
					anim = 4;
				else
					anim = 11;
				break;
			}
			case DIE:
			{
				if ( m_iWeapon <= W_DESERT_EAGLE )
					anim = 5;
				else
					anim = 12;
				break;
			}
			case SPIN_UP: anim = 40; break;
			case SPIN_DOWN: anim = 42; break;
			case WEAPON_OPEN: anim = 7; break;
			case WEAPON_CLOSE:
			{
				if ( m_iWeapon <= W_DESERT_EAGLE )
					anim = 8; // short weapon
				else
					anim = 15; // long weapon
				break;
			}
		}
		return anim;
	}
	
	// Returns how far can the turret see and attack
	int GetRange()
	{
		// These weapons can only attack at melee distance, override it
		if ( m_iWeapon <= W_MEDKIT )
			return 128;
		
		return m_iAttackRange;
	}
	
	/* WEAPON EFFECTS HERE */
	/* Auxiliary functions for Gauss, Egon, and Grapple attacks */
	
	/*
	================
	GAUSS EFFECT
	
	The gauss effects are more than just a beam effect, but
	I've settled on a simple yellow beam for simplicity.
	================
	*/
	void BeamEffect( Vector vecStart, Vector vecEnd, uint8 noise, uint8 R, uint8 G, uint8 B, uint8 alpha )
	{
		NetworkMessage msg( MSG_BROADCAST, NetworkMessages::SVC_TEMPENTITY );
		msg.WriteByte( TE_BEAMPOINTS );
		msg.WriteCoord( vecStart.x );
		msg.WriteCoord( vecStart.y );
		msg.WriteCoord( vecStart.z );
		msg.WriteCoord( vecEnd.x );
		msg.WriteCoord( vecEnd.y );
		msg.WriteCoord( vecEnd.z );
		msg.WriteShort( m_Beam );
		msg.WriteByte( 0 ); // framestart
		msg.WriteByte( 1 ); // framerate
		msg.WriteByte( 1 ); // life
		msg.WriteByte( 10 ); // width
		msg.WriteByte( noise ); // noise
		msg.WriteByte( R );
		msg.WriteByte( G );
		msg.WriteByte( B );
		msg.WriteByte( alpha ); // brightness
		msg.WriteByte( 1 ); // scroll rate
		msg.End();
	}
	
	/*
	================
	EGON EFFECTS
	
	Straight from HLSDK, nothing strange here other than different
	function names to prevent collision with grapple effects.
	================
	*/
	void EgonUpdate( const Vector startPoint, const Vector endPoint, float timeBlend )
	{
		if ( m_pBeam is null )
		{
			EgonCreate();
		}
		
		m_pBeam.SetStartPos( endPoint );
		m_pBeam.SetBrightness( 255 - ( int( timeBlend ) * 180 ) );
		m_pBeam.SetWidth( 40 - ( int( timeBlend ) * 20 ) );
		
		m_pBeam.SetColor( 30 + ( 25 * int( timeBlend ) ), 30 + ( 30 * int( timeBlend ) ), 64 + 80 * int( abs( sin( g_Engine.time * 10 ) ) ) );
		
		g_EntityFuncs.SetOrigin( m_pSprite, endPoint );
		m_pSprite.pev.frame += 8 * g_Engine.frametime;
		if ( m_pSprite.pev.frame > m_pSprite.Frames() )
			m_pSprite.pev.frame = 0;
		
		m_pNoise.SetStartPos( endPoint );
	}

	void EgonCreate()
	{
		EgonDestroy();
		
		@m_pBeam = g_EntityFuncs.CreateBeam( "sprites/xbeam1.spr", 40 );
		m_pBeam.PointEntInit( self.pev.origin, self.entindex() );
		m_pBeam.SetFlags( BEAM_FSINE );
		m_pBeam.SetEndAttachment( 1 );
		m_pBeam.pev.spawnflags |= SF_BEAM_TEMPORARY; // Flag these to be destroyed on save/restore or level transition
		//m_pBeam.pev.flags |= FL_SKIPLOCALHOST;
		@m_pBeam.pev.owner = self.edict();
		
		@m_pNoise = g_EntityFuncs.CreateBeam( "sprites/xbeam1.spr", 55 );
		m_pNoise.PointEntInit( self.pev.origin, self.entindex() );
		m_pNoise.SetScrollRate( 25 );
		m_pNoise.SetBrightness( 100 );
		m_pNoise.SetEndAttachment( 1 );
		m_pNoise.pev.spawnflags |= SF_BEAM_TEMPORARY;
		//m_pNoise.pev.flags |= FL_SKIPLOCALHOST;
		@m_pNoise.pev.owner = self.edict();
		
		@m_pSprite = g_EntityFuncs.CreateSprite( "sprites/xspark1.spr", self.pev.origin, false );
		m_pSprite.pev.scale = 1.0;
		m_pSprite.SetTransparency( kRenderGlow, 255, 255, 255, 255, kRenderFxNoDissipation );
		m_pSprite.pev.spawnflags |= 0x8000; // SF_SPRITE_TEMPORARY
		//m_pSprite.pev.flags |= FL_SKIPLOCALHOST;
		@m_pSprite.pev.owner = self.edict();
		
		m_pBeam.SetScrollRate( 50 );
		m_pBeam.SetNoise( 20 );
		m_pNoise.SetColor( 50, 50, 255 );
		m_pNoise.SetNoise( 8 );
	}
	
	void EgonDestroy()
	{
		if ( m_pBeam !is null )
		{
			g_EntityFuncs.Remove( m_pBeam );
			@m_pBeam = null;
		}
		if ( m_pNoise !is null )
		{
			g_EntityFuncs.Remove( m_pNoise );
			@m_pNoise = null;
		}
		if ( m_pSprite !is null )
		{
			m_pSprite.Expand( 10, 500 );
			@m_pSprite = null;
		}
	}
	
	void EgonEnd()
	{
		g_SoundSystem.StopSound( self.edict(), CHAN_WEAPON, "weapons/egon_run3.wav" );
		g_SoundSystem.EmitSound( self.edict(), CHAN_WEAPON, "weapons/egon_off1.wav", VOL_NORM, ATTN_NORM );
		
		m_iWeaponState = STATE_OFF;
		
		EgonDestroy();
	}
	
	/*
	================
	GRAPPLE EFFECTS
	
	I don't think you need an explanation for these.
	================
	*/
	void GrappleCreate( Vector vecSrc )
	{
		GrappleDestroy();
		
		@m_pTip = cast< CSentryTongue@ >( CastToScriptClass( g_EntityFuncs.CreateEntity( "sentry_tongue", null, false ) ) );
		m_pTip.Spawn();
		
		Math.MakeVectors( m_vecCurAngles );
		
		Vector vecOrigin = vecSrc + g_Engine.v_forward * 16.0 + g_Engine.v_right * 8.0 + g_Engine.v_up * -8.0;
		Vector vecAngles = m_vecCurAngles;
		
		//vecAngles.x = -vecAngles.x;
		
		m_pTip.SetPosition( vecOrigin, vecAngles, self );
		
		if ( m_pBeam is null )
		{
			@m_pBeam = g_EntityFuncs.CreateBeam( "sprites/tongue.spr", 16 );
			
			m_pBeam.EntsInit( m_pTip.self.entindex(), self.entindex() );
			m_pBeam.SetFlags( BEAM_FSOLID );
			m_pBeam.SetBrightness( 100.0 );
			m_pBeam.SetEndAttachment( 1 );
			
			m_pBeam.pev.spawnflags |= SF_BEAM_TEMPORARY;
		}
	}
	
	void GrappleUpdate( Vector vecSrc )
	{
		if ( m_pBeam is null || m_pTip is null )
			GrappleCreate( vecSrc );
	}
	
	void GrappleDestroy()
	{
		if ( m_pBeam !is null )
		{
			g_EntityFuncs.Remove( m_pBeam );
			@m_pBeam = null;
		}
		
		if ( m_pTip !is null )
		{
			g_EntityFuncs.Remove( m_pTip.self );
			@m_pTip = null;
		}
	}
	
	void GrappleEnd()
	{
		m_iWeaponState = STATE_OFF;
		self.pev.fuser1 = 0;
		
		g_SoundSystem.EmitSoundDyn( self.edict(), CHAN_STATIC, "weapons/bgrapple_release.wav", 0.98, ATTN_NORM, 0, 125 );
		g_SoundSystem.EmitSoundDyn( self.edict(), CHAN_STATIC, "weapons/bgrapple_pull.wav", 0.0, ATTN_NONE, SND_STOP, 100 );
		
		GrappleDestroy();
		
		self.pev.movetype = MOVETYPE_STEP;
	}
	
	/* UTILITY CODE HERE */
	/* How many workarounds can you add in a single script file? */
	
	/*
	================
	BestVisibleEnemy
	
	AngelScript's BestVisibleEnemy() does not work.
	Fixed in SC 5.26, do a workaround for now.
	================
	*/
	CBaseEntity@ BestVisibleEnemy( float flDistance, edict_t@ ignoreTarget = null )
	{
		CBaseEntity@ pReturn = null;
		
		// Seeks all possible enemies near
		while( ( @pReturn = g_EntityFuncs.FindEntityInSphere( pReturn, self.pev.origin, flDistance, "*", "classname" ) ) !is null )
		{
			// Monsters or Players only!
			if ( pReturn.pev.FlagBitSet( FL_MONSTER ) || pReturn.pev.FlagBitSet( FL_CLIENT ) )
			{
				// Is hostile to us and still alive? Then consider it as a target
				if ( self.IRelationship( pReturn ) > R_NO && pReturn.IsAlive() && pReturn.edict() !is ignoreTarget && !pReturn.pev.FlagBitSet( FL_NOTARGET ) ) // don't ignore notarget
				{
					// Don't get mad at an enemy we cannot see!
					if ( self.pev.SpawnFlagBitSet( SF_SENTRY_IGNORE_LOS ) || ( self.FInViewCone( pReturn ) && self.FVisible( pReturn, true ) ) )
						return pReturn;
				}
			}
		}
		return null;
	}
	
	/*
	================
	BestVisibleAlly
	
	It's literally a copy-paste of BestVisibleEnemy.
	Search for the nearest alive ally.
	================
	*/
	CBaseEntity@ BestVisibleAlly( float flDistance, edict_t@ ignoreTarget = null )
	{
		CBaseEntity@ pReturn = null;
		
		// Seeks all possible entities near
		while( ( @pReturn = g_EntityFuncs.FindEntityInSphere( pReturn, self.pev.origin, flDistance, "*", "classname" ) ) !is null )
		{
			// Monsters or Players only!
			if ( pReturn.pev.FlagBitSet( FL_MONSTER ) || pReturn.pev.FlagBitSet( FL_CLIENT ) )
			{
				// Is ally to us and still alive? Then consider it as a target
				if ( self.IRelationship( pReturn ) == R_AL && pReturn.IsAlive() && pReturn.edict() !is ignoreTarget && pReturn !is self ) // ignore notarget, and avoid itself
				{
					// Of course, we must be able to see it
					if ( self.pev.SpawnFlagBitSet( SF_SENTRY_IGNORE_LOS ) || ( self.FInViewCone( pReturn ) && self.FVisible( pReturn, true ) ) )
						return pReturn;
				}
			}
		}
		return null;
	}
	
	/*
	================
	MyFireBullets
	
	This is CBaseEntity::FireBulletsPlayer from HLSDK.
	Edited to show decals even when damage is 0, and removes the stupid DMG_ALWAYSGIB bitflag from it.
	The original function has too many arguments to fit within limits (Original has 10, maximum is 8).
	Code had to be simplified to shrink the numbers of args. Always emits tracers every shot.
	================
	*/
	Vector2D MyFireBullets( CBaseEntity@ pAttacker, uint uiBullets, Vector vecSrc, Vector vecDirShooting, Vector vecSpread, float flDistance, int iBulletType, int iDamage )
	{
		TraceResult tr;
		Vector vecRight = g_Engine.v_right;
		Vector vecUp = g_Engine.v_up;
		float x, y;
		
		g_WeaponFuncs.ClearMultiDamage();
		for ( uint uiShot = 1; uiShot <= uiBullets; uiShot++ )
		{
			g_Utility.GetCircularGaussianSpread( x, y );
			
			Vector vecDir = vecDirShooting + x * vecSpread.x * vecRight + y * vecSpread.y * vecUp;
			Vector vecEnd;
			
			vecEnd = vecSrc + vecDir * flDistance;
			g_Utility.TraceLine( vecSrc, vecEnd, dont_ignore_monsters, pAttacker.edict(), tr );
			
			// tracer effect
			NetworkMessage tracer( MSG_PAS, NetworkMessages::SVC_TEMPENTITY, vecSrc );
			tracer.WriteByte( TE_TRACER );
			tracer.WriteCoord( vecSrc.x );
			tracer.WriteCoord( vecSrc.y );
			tracer.WriteCoord( vecSrc.z );
			tracer.WriteCoord( tr.vecEndPos.x );
			tracer.WriteCoord( tr.vecEndPos.y );
			tracer.WriteCoord( tr.vecEndPos.z );
			tracer.End();
			
			// do damage, paint decals
			if ( tr.flFraction != 1.0 )
			{
				g_SoundSystem.PlayHitSound( tr, vecSrc, vecEnd, iBulletType );
				if ( tr.pHit.vars.solid == SOLID_BSP || tr.pHit.vars.movetype == MOVETYPE_PUSHSTEP )
					g_Utility.GunshotDecalTrace( tr, DECAL_GUNSHOT1 + Math.RandomLong( 0, 4 ) );
				
				CBaseEntity@ pEntity = g_EntityFuncs.Instance( tr.pHit );
				
				if ( iDamage != 0 )
					pEntity.TraceAttack( pAttacker.pev, iDamage, vecDir, tr, DMG_BULLET|DMG_NEVERGIB ); // bullets should not gib
				else
				{
					// the sentry works with a player weapon being given to the turret, so OK to use player bullet type
					switch ( iBulletType )
					{
						case BULLET_PLAYER_9MM:
						{
							pEntity.TraceAttack( pAttacker.pev, g_EngineFuncs.CVarGetFloat( "sk_plr_9mm_bullet" ), vecDir, tr, DMG_BULLET|DMG_NEVERGIB ); 
							break;
						}
						case BULLET_PLAYER_MP5:
						{
							pEntity.TraceAttack( pAttacker.pev, g_EngineFuncs.CVarGetFloat( "sk_plr_9mmAR_bullet" ), vecDir, tr, DMG_BULLET|DMG_NEVERGIB ); 
							break;
						}
						case BULLET_PLAYER_BUCKSHOT:
						{
							pEntity.TraceAttack( pAttacker.pev, g_EngineFuncs.CVarGetFloat( "sk_plr_buckshot" ), vecDir, tr, DMG_BULLET|DMG_NEVERGIB ); 
							break;
						}
						case BULLET_PLAYER_357:
						{
							pEntity.TraceAttack( pAttacker.pev, g_EngineFuncs.CVarGetFloat( "sk_plr_357_bullet" ), vecDir, tr, DMG_BULLET|DMG_NEVERGIB ); 
							break;
						}
						case BULLET_PLAYER_SAW: // Shared by monsters
						{
							pEntity.TraceAttack( pAttacker.pev, g_EngineFuncs.CVarGetFloat( "sk_556_bullet" ), vecDir, tr, DMG_BULLET|DMG_NEVERGIB ); 
							break;
						}
						case BULLET_PLAYER_SNIPER:
						{
							pEntity.TraceAttack( pAttacker.pev, g_EngineFuncs.CVarGetFloat( "sk_plr_762_bullet" ), vecDir, tr, DMG_BULLET|DMG_NEVERGIB ); 
							break;
						}
						case BULLET_PLAYER_EAGLE:
						{
							// OP4 has it's own CVar, default of 34. Value should be 51 to match this number.
							pEntity.TraceAttack( pAttacker.pev, g_EngineFuncs.CVarGetFloat( "sk_plr_357_bullet" ) * ( 2.0 / 3.0 ), vecDir, tr, DMG_BULLET|DMG_NEVERGIB );
							break;
						}
						default: // case BULLET_NONE: The default case cannot be the first one
						{
							pEntity.TraceAttack( pAttacker.pev, 50, vecDir, tr, DMG_CLUB );
							g_SoundSystem.PlayHitSound( tr, vecSrc, vecEnd, iBulletType );
							
							// only decal glass
							if ( !FNullEnt( tr.pHit ) && tr.pHit.vars.rendermode != kRenderNormal )
							{
								g_Utility.DecalTrace( tr, DECAL_GLASSBREAK1 + Math.RandomLong( 0, 2 ) );
							}
							
							break;
						}
					}
				}
			}
			
			// make bullet trails
			g_Utility.BubbleTrail( vecSrc, tr.vecEndPos, int( ( flDistance * tr.flFraction ) / 64.0 ) );
		}
		g_WeaponFuncs.ApplyMultiDamage( pAttacker.pev, pAttacker.pev ); // inflictor, attacker
		
		return Vector2D( x * vecSpread.x, y * vecSpread.y );
	}
	
	/*
	=========================================================
	CheckTraceHullAttack
	 
	This is CBaseMonster::CheckTraceHullAttack from HLSDK.
	Edited to make it fit with the sentry attacks (and healing)
	=========================================================
	*/
	CBaseEntity@ CheckTraceHullAttack( float flDist, int iDamage, int iDmgType )
	{
		TraceResult tr;
		
		Math.MakeAimVectors( m_vecCurAngles );
		
		Vector vecStart = self.pev.origin;
		vecStart.z += self.pev.size.z * 0.5;
		Vector vecEnd = vecStart + ( g_Engine.v_forward * flDist );
		
		g_Utility.TraceHull( vecStart, vecEnd, dont_ignore_monsters, head_hull, self.edict(), tr );
		
		CBaseEntity@ pEntity = g_EntityFuncs.Instance( tr.pHit );
		if ( pEntity !is null )
		{
			if ( iDamage > 0 )
			{
				pEntity.TakeDamage( self.pev, self.pev, iDamage, iDmgType );
				
				// Try bleeding
				int blood = pEntity.BloodColor();
				if ( blood != DONT_BLEED )
				{
					//tr.vecEndPos would work if this was a TraceLine, but it's a TraceHull
					g_WeaponFuncs.SpawnBlood( pEntity.BodyTarget( g_vecZero ) - g_Engine.v_forward * 4, blood, float( iDamage ) ); // a little surface blood.
					pEntity.TraceBleed( float( iDamage ), g_Engine.v_forward, tr, iDmgType );
				}
			}
			else
			{
				// Try healing
				if ( pEntity.pev.health >= pEntity.pev.max_health )
					return null; // no effect, pretend trace didn't hit anything
				
				pEntity.TakeHealth( abs( iDamage ), iDmgType );
			}
			return pEntity;
		}
		
		return null;
	}
}

/*
======
Sentry Grapple Tongue

I had to provide a custom one as there is no way to access "grappletongue"'s info from the outside.
======
*/
class CSentryTongue : ScriptBaseEntity
{
	bool m_bIsStuck;
	bool m_bMissed;
	
	EHandle m_hGrappleTarget;
	Vector m_vecOriginOffset;
	
	void Precache()
	{
		g_Game.PrecacheModel( "models/shock_effect.mdl" );
	}
	
	void Spawn()
	{
		Precache();
		
		self.pev.movetype = MOVETYPE_FLY;
		self.pev.solid = SOLID_BBOX;
		
		g_EntityFuncs.SetModel( self, "models/shock_effect.mdl" );
		
		// it should be point sized but to help the tongue catch something, expand +/- 1 unit
		g_EntityFuncs.SetSize( self.pev, Vector( -1, -1, -1 ), Vector( 1, 1, 1 ) );
		
		// Try to compensate monsters f e e t
		self.pev.origin.z += 1;
		g_EntityFuncs.SetOrigin( self, self.pev.origin );
		
		SetThink( ThinkFunction( FlyThink ) );
		SetTouch( TouchFunction( TongueTouch ) );
		
		self.pev.angles.x -= 30.0;
		
		Math.MakeVectors( self.pev.angles );
		
		self.pev.angles.x = -( 30.0 + self.pev.angles.x );
		
		self.pev.velocity = g_vecZero;
		
		self.pev.gravity = 1;
		
		self.pev.nextthink = g_Engine.time + 0.02;
		
		m_bIsStuck = false;
		m_bMissed = false;
	}
	
	void FlyThink()
	{
		Math.MakeAimVectors( self.pev.angles );
		
		self.pev.angles = Math.VecToAngles( g_Engine.v_forward );
		
		const float flNewVel = ( ( self.pev.velocity.Length() * 0.8 ) + 400.0 );
		
		self.pev.velocity = self.pev.velocity * 0.2 + ( flNewVel * g_Engine.v_forward );
		
		float maxSpeed = Math.clamp( 0.0, g_EngineFuncs.CVarGetFloat( "sv_maxvelocity" ), 1600.0 );
		
		if ( self.pev.velocity.Length() > maxSpeed )
		{
			self.pev.velocity = self.pev.velocity.Normalize() * maxSpeed;
		}
		
		self.pev.nextthink = g_Engine.time + 0.02;
	}
	
	// Minimalistic grapple: only get a hold of enemy entities, ignore all else.
	void TongueTouch( CBaseEntity@ pOther )
	{
		if ( pOther is null )
			m_bMissed = true;
		else
		{
			// relationship of owner
			CBaseEntity@ pOwner = g_EntityFuncs.Instance( self.pev.owner );
			if ( pOwner !is null && pOwner.IRelationship( pOther ) > R_NO )
			{
				m_hGrappleTarget = pOther;
				m_vecOriginOffset = self.pev.origin - pOther.pev.origin;
				m_bIsStuck = true;
			}
			else
				m_bMissed = true;
		}
		
		self.pev.velocity = g_vecZero;
		self.pev.solid = SOLID_NOT; // stop interacting with the world
		
		SetThink( null );
		SetTouch( null );
	}
	
	void SetPosition( Vector vecOrigin, Vector vecAngles, CBaseEntity@ pOwner )
	{
		g_EntityFuncs.SetOrigin( self, vecOrigin );
		self.pev.angles = vecAngles;
		@self.pev.owner = pOwner.edict();
	}
	
	bool IsStuck()
	{
		return m_bIsStuck;
	}
	
	bool HasMissed()
	{
		return m_bMissed;
	}
	
	CBaseEntity@ GetGrappleTarget()
	{
		if ( m_hGrappleTarget.IsValid() )
			return m_hGrappleTarget.GetEntity();
		
		return null;
	}
	
	bool ShouldPushTarget()
	{
		CBaseEntity@ pTarget = GetGrappleTarget();
		if ( pTarget !is null )
		{
			// OP4 includes the baby voltigore in its list of entities that
			// can be pushed towards the barnacle, SC does not.
			
			// Use 58 if you want baby voltigores to be pushed towards the sentry.
			// Use 42 if you want to stricly stay with SC mechanics.
			if ( pTarget.pev.size.Length() > 58 )
				return false;
			
			return true;
		}
		
		return false;
	}
}

void RegisterSentryMK2()
{
	g_CustomEntityFuncs.RegisterCustomEntity( "CSentryMK2", "monster_sentry_mk2" );
	g_CustomEntityFuncs.RegisterCustomEntity( "CSentryTongue", "sentry_tongue" );
	g_Game.PrecacheOther( "monster_sentry_mk2" );
}

void MapInit() { RegisterSentryMK2(); }
