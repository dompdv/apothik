Propriétés du cache:
* data peut être regénérée avec une pénalité
* mis-cache pas grave mais on cherche à l'optimiser en cas de perte de noeud
* les data des noeuds répliquées doivent être intègres
* le reviving d'une noeud doit se faire sans pénalité sur les noeud en vie (pas de transfert massif de données)
* pas de deadlock (=> GenServer.cast only, acquittement à gérer manuellement)
* cache:  nb de put << nb de get

Hyp 1: KO
* 1 noeud est master (put, get) et a des replicas (get)
* cast du master avec un ack, pour gestion des replicas morts
=> nécessité d'avoir un journal de transactions

Hyp 2:
* pas de réhydratation
* si demande de k non possédée : cast de récupération auprès d'un autre noeud vivant mais reponse _miss_ en synchrone
* put fait des casts sans acquittements sur les autres noeuds
* au réveil, récupération pro-active des clés d'un backup (en un ou plusieurs paquets de données)
=> Pas d'intégrité des données
=> Comprendre CRDT
