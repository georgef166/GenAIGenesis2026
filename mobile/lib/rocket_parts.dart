/// Describes a named section of the rocket that the user can learn about.
class RocketPart {
  const RocketPart({
    required this.id,
    required this.name,
    required this.shortDescription,
    required this.details,
    required this.emoji,
  });

  /// Unique identifier, also used to look up annotations in the model.
  final String id;

  /// Human-readable display name.
  final String name;

  /// One-line summary shown on chips/buttons.
  final String shortDescription;

  /// Full educational content shown in the detail sheet.
  final String details;

  /// Emoji used as a visual accent in the UI.
  final String emoji;
}

const List<RocketPart> kRocketParts = [
  RocketPart(
    id: 'nose_cone',
    name: 'Nose Cone',
    shortDescription: 'Aerodynamic tip that reduces drag',
    emoji: '🔺',
    details:
        'The nose cone is the foremost section of the rocket. Its pointed or '
        'rounded shape is carefully engineered to minimise aerodynamic drag as '
        'the vehicle accelerates through the atmosphere. On orbital rockets the '
        'nose cone (also called the payload fairing) protects the satellite or '
        'spacecraft until the rocket leaves the dense lower atmosphere, at which '
        'point it is jettisoned to reduce mass.',
  ),
  RocketPart(
    id: 'payload_bay',
    name: 'Payload Bay',
    shortDescription: 'Carries the mission cargo',
    emoji: '📦',
    details:
        'The payload bay houses the actual mission cargo — a satellite, '
        'space telescope, crew capsule, or supply vehicle. It is thermally '
        'insulated and mechanically isolated to protect sensitive equipment '
        'from the vibration and heat of launch. Separation bolts release the '
        'payload precisely when the target orbit is reached.',
  ),
  RocketPart(
    id: 'guidance_system',
    name: 'Guidance System',
    shortDescription: 'Navigation brain of the rocket',
    emoji: '🧭',
    details:
        'The guidance system is the onboard computer and sensor suite that '
        'steers the rocket along its planned trajectory. Inertial measurement '
        'units (IMUs) track acceleration and rotation in three axes, while GPS '
        'receivers provide absolute position fixes. The flight computer '
        'continuously compares actual state with the planned trajectory and '
        'issues corrections to the engine gimbal and grid fins.',
  ),
  RocketPart(
    id: 'propellant_tanks',
    name: 'Propellant Tanks',
    shortDescription: 'Stores fuel and oxidiser',
    emoji: '🛢️',
    details:
        'Propellant tanks occupy the majority of a rocket\'s volume. A typical '
        'liquid-propellant rocket carries separate tanks for fuel (e.g. liquid '
        'hydrogen or RP-1 kerosene) and oxidiser (liquid oxygen). The tanks are '
        'pressurised to push propellants into the turbopumps at the correct flow '
        'rate. Because the tanks must be both lightweight and structurally rigid, '
        'they are often made from aluminium-lithium alloys or carbon-fibre '
        'composites.',
  ),
  RocketPart(
    id: 'interstage',
    name: 'Interstage',
    shortDescription: 'Connects and separates stages',
    emoji: '🔗',
    details:
        'The interstage is the structural adapter that connects two propulsive '
        'stages. At staging, pyrotechnic separation bolts fire simultaneously '
        'around the interstage ring, cleanly detaching the exhausted lower stage. '
        'Grid fins or cold-gas thrusters push the stages apart to prevent '
        're-contact. On reusable rockets like Falcon 9, the interstage also '
        'anchors the landing legs in their stowed position.',
  ),
  RocketPart(
    id: 'engine',
    name: 'Main Engine(s)',
    shortDescription: 'Generates thrust by burning propellant',
    emoji: '🔥',
    details:
        'Rocket engines burn fuel and oxidiser in a combustion chamber, '
        'converting chemical energy into hot, high-pressure gas. This gas '
        'expands through a bell-shaped nozzle, accelerating to supersonic '
        'speeds and producing thrust via Newton\'s third law. Modern engines '
        'such as SpaceX\'s Merlin or Raptor use a turbopump cycle driven by '
        'a small fraction of the propellant flow to pressurise the main '
        'propellant lines. Engine gimballing — tilting the nozzle — steers '
        'the rocket in flight.',
  ),
  RocketPart(
    id: 'landing_legs',
    name: 'Landing Legs',
    shortDescription: 'Enable propulsive vertical landing',
    emoji: '🦵',
    details:
        'On reusable rockets, four to eight deployable legs are folded flush '
        'against the first stage during ascent. Shortly before touchdown the '
        'legs are released by pneumatic actuators and lock into position, '
        'providing a stable base for the vertical propulsive landing. The legs '
        'are built from carbon-fibre and aluminium honeycomb to be lightweight '
        'yet strong enough to absorb the landing impulse.',
  ),
  RocketPart(
    id: 'grid_fins',
    name: 'Grid Fins',
    shortDescription: 'Aerodynamic control during descent',
    emoji: '🔲',
    details:
        'Grid fins are lattice-structured control surfaces that fold out from '
        'the top of the first stage after separation. As the stage falls back '
        'through the atmosphere, the grid fins are actuated by electric motors '
        'to steer it toward the landing zone with metre-level precision. Their '
        'open lattice design provides high drag with relatively low structural '
        'weight, and titanium construction lets them survive the intense heat '
        'of re-entry.',
  ),
];
