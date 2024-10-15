Step 6:

Il faut faire un seul cache.

L'idée:
- envoyer la demande au bon Node

On a recherché:
- appremment Procerss.send a l'air bien
- comment ça marche avec GenServer

Master >
Process.send() avec {dest,node)}
On fait un handle_info pour voir si ça marche

@impl true
  def handle_info(msg, state) do
    IO.inspect(msg)
    {:noreply, state}
  end

Du coup, on essaie directement avec GenServer.call

[14/10/2024 21:04:15] Olivier Belhomme: GenServer.call({Apothik.Cache, :"apothik_1@127.0.0.1"}, {:put, 1, "coucou"})
[14/10/2024 21:04:26] Olivier Belhomme: iex(master@127.0.0.1)5> GenServer.call({Apothik.Cache, :"apothik_1@127.0.0.1"}, :stats)


- trouver dans quelle machine est stockée la clé (hash)

Le problème est key_to_node
On veut une fonction de hashing quelconque: 
- phash2(clé, range)  renvoie un nombre enrte 0 et range - 1 
petite refactoring pour créer le module Cluster
- On envoie la demande sur le serveur
- master.put et master.get 
- on sait pas où il est. Master.stat(4) -> 1
- car :erlang.phash2("coucou", 5) == 3

Test de remplissage
on ajoute dans .iex une stat global
- Master.fill(1, 5000)
- Master.stat()  [1026, 996, 1012, 1021, 945]

COMMIT => on a un cache distribué

==================
PHASE 2: Ajout et suppression de machines

Comment enlever une machine ou ajouter une machine du cluster.


On ajoute un moyen de tuer un Node (Node.stop)
{:error, :not_allowed}; En fait, c'est System.stop
Master.stat() -> ex(master@127.0.0.1)5> Master.stat
[{1, {:badrpc, :nodedown}}, {2, 996}, {3, 1012}, {4, 1021}, {5, 945}]



Première étape, utliser Node.list;
iex(master@127.0.0.1)6> Master.fill(1, 5000)
:ok
iex(master@127.0.0.1)7> Master.stat
[{1, 825}, {2, 827}, {3, 814}, {4, 834}, {5, 817}]
iex(master@127.0.0.1)8> Master.stat
[{1, 825}, {2, 827}, {3, 814}, {4, 834}, {5, 817}]
iex(master@127.0.0.1)9> Node.list
[:"apothik_1@127.0.0.1", :"apothik_4@127.0.0.1", :"apothik_5@127.0.0.1",
 :"apothik_2@127.0.0.1", :"apothik_3@127.0.0.1"]

 On a perdu 1000 trucs
VOIR le COMMIT 2.1T => première erreur 

Node.monitor :net_kernel.monitor_nodes(true)
POur voir les événements
Ajouter le Apothik.Cluster dans Application (supervision) (après le libcluster)
Ca marche pas (pas de nodeup)
On inverse et on met libcluster après => ça marche

Est ce que libcluster est synchrone ? => dans le shell Start_cluster, aller que jusqu'à 4.

On ajouter les handle_info(:nodeup et :nodedown)

===> impact sur le cache
On change le nb_nodes => on ajoute une fonction

Test => 


Comment ajouter un noeud à la volée ? => pb de numérotation ensuite





