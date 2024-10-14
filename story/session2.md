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



