# Apothik

Ce dépôt a été créé pour explorer le développement d'applications distribuées avec [Olb17](https://github.com/olb17).

---

## Français

**Apothik** est notre terrain d'expérimentation pour apprendre les applications distribuées avec Elixir et Erlang. Inspirés par la conférence de Johanna Larsonn à Code BEAM Lite Mexico 2023, nous avons voulu prouver que des développeurs ordinaires peuvent s'attaquer à ce domaine intimidant — non pas seuls, mais en équipe, à quatre mains, avec un créneau hebdomadaire réservé à l'exploration.

Plutôt que de viser d'emblée une base de données distribuée tolérante aux pannes, nous avons choisi un objet d'étude simple — un cache clé-valeur — et une progression en trois phases : cluster fixe, cluster dynamique, puis redondance de stockage. Chaque phase ajoute une contrainte réaliste du monde distribué, sans noyer le lecteur sous la théorie.

Ce dépôt contient le code source de ces expériences ainsi qu'une série de trois articles racontant notre chemin : les tentatives, les erreurs, et parfois les réussites. Ce n'est pas un cours magistral, c'est le récit non censuré de notre découverte.

### Articles (français)

**[Partie 1 — Un cache distribué, sans redondance, sur 5 machines fixes](docs/stories/fr_story_phase1.md)**  
Nous posons les fondations : lancement de cinq nœuds Erlang sur une seule machine, connexion via `libcluster`, puis construction d'un cache clé-valeur réparti par hachage des clés. Chaque nœud héberge une portion du cache ; toute requête peut être adressée à n'importe quel nœud du cluster, qui redirige automatiquement vers le bon serveur.

**[Partie 2 — Un cache distribué, sans redondance, avec un cluster dynamique](docs/stories/fr_story_phase2.md)**  
Les machines entrent et sortent du cluster : nous monitorons les nœuds avec `:net_kernel.monitor_nodes/1`, adaptons la répartition des clés au nombre de machines vivantes, et explorons deux stratégies de distribution — tokens et hash ring — pour limiter les déplacements de données lors des changements de topologie.

**[Partie 3 — Garantir la conservation des données malgré la perte de machine](docs/stories/fr_story_phase3.md)**  
La phase la plus exigeante : ajouter de la redondance pour survivre à la panne d'un nœud. Nous abandonnons le modèle maître/réplica au profit de groupes symétriques de trois nœuds, multiplions les écritures, puis synchronisons l'état avec des CRDT (`DeltaCrdt`) pour converger malgré les partitions réseau.

### Articles (English)

- [Part 1 — A Distributed Cache, Without Redundancy, on 5 Fixed Machines](docs/stories/en_story_phase1.md)
- [Part 2 — A Distributed Cache, Without Redundancy, with a Dynamic Cluster](docs/stories/en_story_phase2.md)
- [Part 3 — Ensuring Data Preservation Despite Machine Failure](docs/stories/en_story_phase3.md)

---

## English

This repository was created to explore distributed application development together with [Olb17](https://github.com/olb17).

**Apothik** is our playground for learning distributed applications with Elixir and Erlang. Inspired by Johanna Larsonn's talk at Code BEAM Lite Mexico 2023, we wanted to prove that ordinary developers can tackle this intimidating field — not alone, but as a team, four hands on the keyboard, with a weekly time slot reserved for exploration.

Rather than aiming straight for a fault-tolerant distributed database, we chose a simple study object — a key-value cache — and a three-phase progression: fixed cluster, dynamic cluster, then storage redundancy. Each phase adds a realistic constraint of the distributed world without drowning the reader in theory.

This repository contains the source code for these experiments as well as a series of three articles telling our journey: the attempts, the mistakes, and sometimes the successes. It is not a masterclass; it is the uncensored account of our discovery.

### Articles (English)

**[Part 1 — A Distributed Cache, Without Redundancy, on 5 Fixed Machines](docs/stories/en_story_phase1.md)**  
We lay the foundations: starting five Erlang nodes on a single machine, connecting them via `libcluster`, then building a key-value cache partitioned by key hashing. Each node hosts a portion of the cache; any request can be sent to any node in the cluster, which automatically forwards it to the right server.

**[Part 2 — A Distributed Cache, Without Redundancy, with a Dynamic Cluster](docs/stories/en_story_phase2.md)**  
Machines join and leave the cluster: we monitor nodes with `:net_kernel.monitor_nodes/1`, adapt key distribution to the number of live machines, and explore two distribution strategies — tokens and hash ring — to limit data movement when the topology changes.

**[Part 3 — Ensuring Data Preservation Despite Machine Failure](docs/stories/en_story_phase3.md)**  
The most demanding phase: adding redundancy to survive node failure. We abandon the master/replica model in favor of symmetric groups of three nodes, multiply writes, then synchronize state with CRDTs (`DeltaCrdt`) to converge despite network partitions.

### Articles (français)

- [Partie 1 — Un cache distribué, sans redondance, sur 5 machines fixes](docs/stories/fr_story_phase1.md)
- [Partie 2 — Un cache distribué, sans redondance, avec un cluster dynamique](docs/stories/fr_story_phase2.md)
- [Partie 3 — Garantir la conservation des données malgré la perte de machine](docs/stories/fr_story_phase3.md)
