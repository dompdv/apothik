# Jeu sur les suppression et ajout de machines

cluster + fill + stats
=> stats équilibrées

on tue la machine 2 + stats
=> on observe une machine morte avec 996 keyx perdues

on ajoute une machine 2 avec une commande manuelle : `% elixir --name "apothik_2@127.0.0.1" -S mix run --no-halt` : Attention run-no-halt est nécessaire pour redemarer la machine 2 car sinon elle s'arrete toute seule.

```
% ./scripts/start_master.sh
Erlang/OTP 26 [erts-14.2.2] [source] [64-bit] [smp:8:8] [ds:8:8:10] [async-threads:1] [jit] [dtrace]

Interactive Elixir (1.16.2) - press Ctrl+C to exit (type h() ENTER for help)
iex(master@127.0.0.1)1> Master.fill(1,5000)
:ok
iex(master@127.0.0.1)2> Master.stat
[{1, 1026}, {2, 996}, {3, 1012}, {4, 1021}, {5, 945}]
iex(master@127.0.0.1)3> Master.kill(2)
:ok
iex(master@127.0.0.1)4> Master.stat
[
  {1, 1026},
  {2, {:badrpc, :nodedown}},
  {3, 1012},
  {4, 1021},
  {5, 945}
]
9> Node.list
[:"apothik_1@127.0.0.1", :"apothik_5@127.0.0.1",
 :"apothik_4@127.0.0.1", :"apothik_3@127.0.0.1",
 :"apothik_2@127.0.0.1"]
iex(master@127.0.0.1)10> Master.stat
[{1, 1026}, {2, 0}, {3, 1012}, {4, 1021}, {5, 945}]
iex(master@127.0.0.1)11> Master.fill(1,5000)
:ok
iex(master@127.0.0.1)12> Master.stat
[{1, 1026}, {2, 996}, {3, 1012}, {4, 1021}, {5, 945}]
iex(master@127.0.0.1)13>
```

Tentative d'ajout d'une machine 6 manuellement.
Master.fill(5000) -> remplissage équilibré sur les 6 machines.
```
14> Enum.map(1..6, fn i -> {i,Master.stat(i)} end)
[
  {1, 1026},
  {2, 996},
  {3, 1012},
  {4, 1021},
  {5, 945},
  {6, 0}
]
iex(master@127.0.0.1)15> Master.fill(1,5000)
:ok
iex(master@127.0.0.1)16> Enum.map(1..6, fn i -> {i,Master.stat(i)} end)
[
  {1, 1683},
  {2, 1668},
  {3, 1673},
  {4, 1679},
  {5, 1589},
  {6, 883}
]
```
# key_to_node implem en ETS
utilisation de rpc depuis master : lancement d'un processus distant donc avec accès à ETS.

init du Cache : création de l'ETS avec named_table et protected (pour accès concurrents).

Remplacement de IO.inspect par Logger.

Test :

on relance le cluster + master + fill(4, 5_000) + stats

la répartition des clés dépend du noeud sur lequel on insère, parce que le k généré par fill(noeud, 5000) dépend du noeud destination.

# hashing manuel : niveau d'indirection sur le hashing de clés
on répartit les nodes sur 1000 tokens.
structure de données (node |-> liste de tokens) conservées dans un ets.

Utilisation d'un ets.match pour lister les clés/valeur d'ETS.

test avec start cluster + master + fill(1, 1000) => clés bien distribuées sur les 5 noeuds

Implémentation de l'ajout et la suppression de noeuds. cauchemar algorithmique :)
on ajoute un noeud 6. On ajoute une fonction get_token (sans passer par un genserver car l'ETS est lisible par tout le monde).
On observe que l'on a pas perdu de token avec une nouvelle fonction get_tokens().
```
tk = Master.get_tokens(1)
(for [n,t]<-tk, do: t) |> List.flatten() |> Enum.uniq() |> length
```
on refait le fill(1, 5000) => clés bien distribuées sur les 5 noeuds
on kill le noeud 2.

```
6> (for {_,s}<- Master.stat ,is_integer(s), do: s) |> Enum.sum()
5000
iex(master@127.0.0.1)7> Master.stat
[{1, 1265}, {2, {:badrpc, :nodedown}}, {3, 1238}, {4, 1224}, {5, 1273}]
iex(master@127.0.0.1)8>
```

on observe que les noeuds ne sont pas dupliqués et sont répartis sur les 4 noeuds restants.

