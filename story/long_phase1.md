# Un voyage à la découverte des applications distribuées avec Elixir

## Pourquoi ?

Elixir et Erlang sont des technologies très cool que nous aimons et pratiquons depuis longtemps (comme un hobby pour l'instant, hélas). Rien que les processus légers et le passage de messages sont la clé d'un nombre infini d'applications, même sur un seul serveur. Il suffit de penser à la magie derrière Liveview, les Channels, Presence et Pubsub par exemple.

Mais la vraie promesse a toujours été l'espoir que des gens ordinaires comme nous puissent s'attaquer aux problèmes d'ingénierie très difficiles qui se posent dans le monde des applications *distribuées*.

Inspirés par l'excellent exposé de [Johanna Larsonn à Code Beam Lite Mexico 2023]![https://www.youtube.com/watch?v=7yU9mvwZKoY], nous avons décidé d'être la preuve vivante que son objectif a été atteint : inspirer certains d'entre nous, simples mortels, à oser s'attaquer à ce monde mystérieux.

Mais commencer seul était intimidant.  Nous avons décidé de faire équipe (Olivier & Dominique, deux vieux amis et amateurs d'Elixir) en s'attaquant à ce défi à 4 mains. Et d'abord de réserver un créneau horaire hebdomadaire pour voyager ensemble.

Cette série d'articles est le récit non censuré de nos tentatives. Ce n'est pas un cours sur la programmation décentralisée, c'est l'histoire de comment nous avons essayé, trébuché et parfois réussi sur ce chemin.

## Le plan d'ensemble

Parce que le sujet est difficile, nous ne pouvions pas sauter directement sur nos claviers et coder une base de données distribuée, tolérante aux fautes et massivement extensible.  Nous avons dû concevoir un plan avec une courbe d'apprentissage que l'on espère douce. Grâce à nos premières lectures et un premier vernis, nous avons conçu un plan par phase qui ressemblait un peu à cela:
- *Quelle application?* La question n'est pas de créer une application complexe, mais plutôt de lui donner les bonnes qualités dans un contexte distribué. Choisissons un simple cache clé-valeur.
- *Phase 1 :* Un Cache distribué, sans redondance, sur 5 machines fixes.
- *Phase 2 :* Même chose, mais avec avec un cluster dynamique (ajout et perte de machine). Explorer l'influence des fonctions de répartition des clés.
- *Phase 3 :* Ajout de redondance de stockage (la clé est recopiée sur plusieurs machines) pour garantir la conservation des données malgré la perte de machine. Gérer un cluster dynamique et des pannes
- *Phase 4 :* Si on arrive là, on peut se rapprocher de l'idée d'une base de données: conservation d'un état sur un cluster dynamique sans perte de données et avec une garantie d'atomicité sur les changements. 

Et bien sûr, cela implique de développer des petits outils annexes pour procéder aux expériences: charger le cache, observer l'état des machines, ajouter ou supprimer des machines, etc

## C'est parti !

