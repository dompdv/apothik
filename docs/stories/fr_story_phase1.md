---
title: A la découverte des applications distribuées avec Elixir - Partie 1
---

<a href="/apothik/">Accueil</a>
<a href="fr_story_phase2.html"> Partie 2</a>
<a href="fr_story_phase3.html"> Partie 3</a>

# Partie 1 : Un Cache distribué, sans redondance, sur 5 machines fixes

## Pourquoi ?

Elixir et Erlang sont des technologies très cool que nous aimons et pratiquons depuis longtemps (comme un hobby pour l'instant, hélas). Rien que les processus légers et le passage de messages sont la clé d'un nombre infini d'applications, même sur un seul serveur. Il suffit de penser à la magie derrière Liveview, les Channels, Presence et Pubsub par exemple.

Mais la vraie promesse a toujours été l'espoir que des gens ordinaires comme nous puissent s'attaquer aux problèmes d'ingénierie très difficiles qui se posent dans le monde des applications *distribuées*.

Inspirés par l'excellent exposé de [Johanna Larsonn à Code Beam Lite Mexico 2023](https://www.youtube.com/watch?v=7yU9mvwZKoY), nous avons décidé d'être la preuve vivante que son objectif a été atteint : inspirer certains d'entre nous, simples mortels, à oser s'attaquer à ce monde mystérieux.

Mais commencer seul était intimidant.  Nous avons décidé de faire équipe (Olivier & Dominique, deux vieux amis et amateurs d'Elixir) en s'attaquant à ce défi à 4 mains. Et d'abord de réserver un créneau horaire hebdomadaire pour voyager ensemble.

Cette série d'articles est le récit non censuré de nos tentatives. Ce n'est pas un cours sur la programmation décentralisée, c'est l'histoire de comment nous avons essayé, trébuché et parfois réussi sur ce chemin.

## Le plan d'ensemble

Parce que le sujet est difficile, nous ne pouvions pas sauter directement sur nos claviers et coder une base de données distribuée, tolérante aux fautes et massivement extensible.  Nous avons dû concevoir un plan avec une courbe d'apprentissage que l'on espère douce. Grâce à nos premières lectures et un premier vernis, nous avons conçu un plan par phase qui ressemblait un peu à cela:
- *Quelle application?* La question n'est pas de créer une application complexe, mais plutôt de lui donner les bonnes qualités dans un contexte distribué. Choisissons un simple cache clé-valeur.
- *Phase 1 :* Un Cache distribué, sans redondance, sur 5 machines fixes.
- *Phase 2 :* Même chose, mais avec un cluster dynamique (ajout et perte de machine). Explorer l'influence des fonctions de répartition des clés.
- *Phase 3 :* Ajout de redondance de stockage (la clé est recopiée sur plusieurs machines) pour garantir la conservation des données malgré la perte de machine

Et bien sûr, cela implique de développer des petits outils annexes pour procéder aux expériences: charger le cache, observer l'état des machines, ajouter ou supprimer des machines, etc

## Préparons le terrain

### Les noeuds
Mais avant de pouvoir écrire du Elixir, il faut bien être capable de le faire tourner sur plusieurs machines. En réalité, il n'est pas besoin d'avoir plusieurs machines pour débuter. En effet, la fondation d'Erlang est une machine virtuelle, la **BEAM**, qui exécute le **Erlang Runtime System**, [détails ici](https://www.erlang.org/blog/a-brief-beam-primer/). Il est possible de démarrer plusieurs machines Erlang, sur un seul ordinateur. Vous allez me dire que ça n'est pas représentatif d'un cluster de 5 machines séparée. En général oui, mais pas pour Erlang qui rend cela transparent. Un message va s'envoyer de la même façon entre deux processus qu'ils soient situés dans la même machine virtuelle, dans deux machines virtuelles différentes, ou même que les machines virtuelles soient situées sur deux machines physiques différentes. L'appel sera le même mais, bien sûr, les propriétés du système pourront être différentes, car il faudra compter avec la latence, les possibilités de panne de réseau entre machines physiques, etc.

Des machines virtuelles Erlang qui communiquent s'appellent des noeuds (voir [introduction à Erlang distribué](https://www.erlang.org/docs/17/reference_manual/distributed)). En Elixir, un module spécifique permet de le manipuler, le [module `Node`](https://hexdocs.pm/elixir/1.12/Node.html).

Nous allons voir comment démarrer des noeuds qui communiquent entre eux.


### Lancer 5 machines

Avant le cluster, créons notre application `apothik`, avec un petit coup de `mix`. `mix new apothik --sup`. Puis `cd apothik && mix apothik` pour vérifier que tout va bien jusque là. Nous avons choisi de créer une application avec supervision (`--sup`). A dire vrai, nous l'avions fait sans superviseur au début, mais nous avons été obligé d'en rajouter un très vite. A la réflexion, une application Elixir sans superviseur est très rare.

Maintenant, demandons à une IA de nous faire un script de lancement de 5 machines Erlang. Après avoir supprimé beaucoup de code inutile et adapté les commentaires, voilà le résultat, dans `/scripts/start_cluster.sh`:

```bash
#!/usr/bin/env bash

NUM_INSTANCES=5
APP_NAME="apothik"

start_instance() {
  local instance_id=$1
  local node_name="${APP_NAME}_${instance_id}@127.0.0.1"

  echo "Starting instance $instance_id with node $node_name..."

  # The node name and cookie need to be set for clustering
  # Here, there is no cookie: the standard ~/.erlang.cookie file is automatically used (and generated if there is none)
  elixir --name $node_name -S mix run --no-halt &
}

mix compile

for i in $(seq 1 $NUM_INSTANCES); do
  start_instance $i
done

wait

```

Tout se joue au lancement de `elixir` (faire un `man elixir`, c'est très instructif). Chaque noeud a un nom de la forme `nom@ip_address`, indiqué par `--name`. 
On lance l'application en lançant le script `mix run --no-halt`.  

`--no-halt`garde la machine virtuelle Elixir en route même si l'application se termine. Sans cela, et parce que notre application ne fait encore rien, la machine virtuelle s'arrêterait 
tout de suite.

Le `&`indique de le lancer sur un processus (un processus de l'OS) fils du script bash.  Ainsi, la commande ne bloque pas le script, et les machines seront arrêtées quand le script s'arrête. 
`wait` suspend le script. Cela permet d'arrêter par `ctrl-C` le script et en cascade toutes les machines virtuelles.

Nous avons dû ajouter `mix compile` en amont car le lancement en parallèle de plusieurs `mix run` pouvait lancer des compilations qui se marchaient sur les pieds.

Un petit `chmod u+x ./scripts/start_cluster.sh` pour donner des droits d'exécution au script bash, et vous pouvez lancer vos 5 machines `./scripts/start_cluster.sh` !

### Créer un cluster

Pour l'instant, les 5 machines ne se connaissent pas, elles vivent leur vie indépendantes l'une de l'autre. Pour former un cluster, il faut qu'elles se reconnaissent entre elles.
Après avoir lancé vos machines dans un terminal, ouvrez un autre terminal et lancez `iex`.

```
% iex                        
iex(1)> Node.ping(:"apothik_1@127.0.0.1")
:pang
```

La fonction [`Node.ping`](https://hexdocs.pm/elixir/1.12/Node.html#ping/1) permet de connecter deux noeuds. 
Elle répond `:pang` en cas d'échec, et `:pong` en cas de succès. Similaire à [`Node.connect`](https://hexdocs.pm/elixir/1.12/Node.html#connect/1) en plus drôle.

Note importante, le nom complet du noeud est un atome. Nous avons écrit `:"apothik_1@127.0.0.1"` et non `"apothik_1@127.0.0.1"`, en préfixant par `:`.

Après tentatives et tests, nous avons compris qu'il faut donner un nom à notre session `iex`.

```
iex --name master@127.0.0.1
1> Node.ping(:"apothik_1@127.0.0.1")
:pong
```

**Ca marche** ! 

On en profite pour mettre `iex --name master@127.0.0.1` dans `/scripts/start_master.sh`.

Continuons:

```terminal
2> Node.list
[:"apothik_1@127.0.0.1"]
3> Node.ping(:"apothik_2@127.0.0.1")
:pong
4> Node.list
[:"apothik_1@127.0.0.1", :"apothik_2@127.0.0.1"]
6> :rpc.call(:"apothik_2@127.0.0.1", Node, :list, [])
[:"master@127.0.0.1", :"apothik_1@127.0.0.1"]
```

`Node.list` liste tous les noeuds du cluster, à l'exception de l'appelant. Au fur et à mesure que l'on connecte un noeud, le cluster s'agrandit. 

Il est possible d'appeler à distance une fonction ("Remote procedure call") à l'aide du module Erlang [`rpc`](https://www.erlang.org/doc/apps/kernel/rpc.html). 
Quand on appelle `Node.list`sur `apothik_2@127.0.0.1`, on constate que ce noeud a une vision complète de de tous les noeuds du cluster. Il suffit donc de se
connecter à *un seul* noeud du cluster pour le rejoindre et que tous les autres noeuds soient automatiquement mis au courant! La magie d'Erlang!

Mais, minute, il me semble qu'il y a une faille de sécurité: on pourrait se connecter à un noeud à partir de son nom, puis exécuter n'importe quel code dessus?
Pas vraiment, quand on lance une machine virtuelle Erlang, elle est associée avec un `cookie`(une chaine de caractère secrète). Seules les machines
lancées avec le même `cookie` peuvent se connecter entre elles. On peut specifier le cookie avec `--cookie`, mais si on ne le fait pas, le fichier
`~/.erlang.cookie` est utilisé (et généré s'il n'existe pas). Comme on a lancé les machines du même utilisateur, elles avaient le même cookie.

**Attention**, le cookie n'est qu'un moyen de partitionner les clusters sur un même réseau physique (pour déployer un cluster de dév sur la même machine qu'un cluster de qualification, par exemple). Il ne protège pas des attaques malveillantes! Si le cluster est déployé sur un réseau public, il faudra adopter des mesures de sécurité supplémentaires : chiffrement inter-noeuds, authentification, etc.

### Découverte automatique des noeuds entre eux

Pour que le cluster se "monte" automatiquement, il faut que les noeuds se connectent entre eux au démarrage de l'application.
Dans un cas aussi simple, c'est facile, car on a une liste connue de noeuds. Même s'il faut bien s'assurer de tenir compte des temps de démarrage des différents noeuds. 

Mais autant s'appuyer sur le travail des autres (tant que ça n'est pas de la magie noire pour nous) et faire appel à [`libcluster`](`https://github.com/bitwalker/libcluster`). 
Cette librairie gère une série de politiques de découverte, des simples au plus avancées (via DNS, multicast ...).

Ajoutons là dans `mix.exs`
```elixir
  defp deps do
    [
      {:libcluster, "~> 3.4"}
    ]
```

(ne pas oublier le `mix deps.get`)
Elle se lance dans l'arbre de supervision, dans `/lib/apothik/application.ex`
```elixir
defmodule Apothik.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    hosts = for i <- 1..5, do: :"apothik_#{i}@127.0.0.1"

    topologies = [
      apothik_cluster_1: [
        strategy: Cluster.Strategy.Epmd,
        config: [hosts: hosts]
      ]
    ]

    children = [
      {Cluster.Supervisor, [topologies, [name: Apothik.ClusterSupervisor]]},
      Apothik.Cache
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Apothik.Supervisor)
  end
end
```

Nous utilisons la stratégie de découverte la plus simple, via une liste finie de noms de noeuds, passée en paramètre du superviseur de `libcluster`:
```elixir
{Cluster.Supervisor, [topologies, [name: Apothik.ClusterSupervisor]]}
```

Lancez `./scripts/start_cluster.sh` et vous verrez les noeuds se découvrir:
```
17:32:13.703 [info] [libcluster:apothik_cluster_1] connected to :"apothik_2@127.0.0.1"
etc...
```

Dans l'autre terminal, vérifiez que le cluster est monté:
```
% ./scripts/start_master.sh
1> Node.ping(:"apothik_1@127.0.0.1")
:pong
2> Node.list
[:"apothik_1@127.0.0.1", :"apothik_2@127.0.0.1", :"apothik_5@127.0.0.1",
 :"apothik_3@127.0.0.1", :"apothik_4@127.0.0.1"]
```

Ca y est, nous pouvons lancer une application sur 5 serveurs qui forment un cluster Elixir !
Nous pouvons démarrer la Phase 1

## Phase 1 : Un Cache distribué, sans redondance, sur 5 machines fixes.

### Ajoutons un système de cache

Cet exemple est tellement classique qu'il est dans le tutorial officiel d'Elixir.

```elixir
defmodule Apothik.Cache do
  use GenServer

  # Interface
  def get(k), do: GenServer.call(__MODULE__, {:get, k})

  def put(k, v), do: GenServer.call(__MODULE__, {:put, k, v})

  def delete(k), do: GenServer.call(__MODULE__, {:delete, k})

  def stats(), do: GenServer.call(__MODULE__, :stats)

  def start_link(args), do: GenServer.start_link(__MODULE__, args, name: __MODULE__)

  # Implementation
  @impl true
  def init(_args), do: {:ok, %{}}

  @impl true
  def handle_call({:get, k}, _from, state), do: {:reply, Map.get(state, k), state}

  def handle_call({:put, k, v}, _from, state), do: {:reply, :ok, Map.put(state, k, v)}

  def handle_call({:delete, k}, _from, state), do: {:reply, :ok, Map.delete(state, k)}

  def handle_call(:stats, _from, state), do: {:reply, map_size(state), state}
end
```

Notez la fonction `stats` qui pour l'instant renvoie la taille du cache.

Et dans `application.ex`, on ajoute le système de cache dans la supervision:
```elixir
children = [
    {Cluster.Supervisor, [topologies, [name: Apothik.ClusterSupervisor]]},
    Apothik.Cache
]
```

Attention cependant à ce code anodin, beaucoup de choses doivent être notées. 
Quand on ajoute `Apothik.Cache` dans la supervision, la fonction `Apothik.Cache.start_link/1` est appelée, qui appelle `GenServer.start_link/3` dont la [documentation](https://hexdocs.pm/elixir/1.16.2/GenServer.html#start_link/3) vaut le détour. 

Le point crucial ici est l'emploi de l'option `:name` avec un nom unique, le nom du module. Ce nom est inscrit dans un dictionnaire **propre à la machine virtuelle**.
Cela permet d'envoyer un message à ce processus `GenServer` sans connaître son identifiant de processus (`pid`). Voir la [documentation](https://hexdocs.pm/elixir/1.16.2/GenServer.html#module-name-registration) pour d'autres possibilités. 

C'est ce qui permet, dans le code suivant, que le message arrive au bon processus:
```elixir
def get(k), do: GenServer.call(__MODULE__, {:get, k})
```

Comme ce nom est unique à la machine virtuelle, il y aura donc 5 processus de gestion de cache, de même nom, un par machine.

Maintenant, retour dans le terminal:

```
% ./scripts/start_master.sh 
4> :rpc.call(:"apothik_1@127.0.0.1", Apothik.Cache, :stats, [])
0
5> :rpc.call(:"apothik_1@127.0.0.1", Apothik.Cache, :put, [:toto, 12])
:ok
6> :rpc.call(:"apothik_1@127.0.0.1", Apothik.Cache, :stats, [])
1
```

Pourquoi passer par le `:rpc`? Nous avons seulement fait `iex`. L'application n'est pas lancée, donc le module `Apothik.Cache` est inconnu de cette machine virtuelle. ùNous pourrions lancer l'application aussi en faisant un `iex -S mix run`, et utiliser directement des fonctions comme `Apothik.Cache.get/1`, mais on court le risque d'avoir notre `master` considéré comme faisant partie du cluster. D'ailleurs, essayez de le lancer pour voir les messages d'erreur de `libcluster`. 

Dernier point, pour nous simplifier la vie, nous avons créé un fichier `.iex.exs`. Ce script est lancé au démarrage de `iex` et permet de créer un contexte aux sessions de `iex` et notamment de charger des fonctions utilitaires.

Ici, ajoutons des fonctions permettant de jouer avec nos caches.

```elixir
defmodule Master do
  def stat(i) do
    :rpc.call(:"apothik_#{i}@127.0.0.1", Apothik.Cache, :stats, [])
  end
  def get(i, k) do
    :rpc.call(:"apothik_#{i}@127.0.0.1", Apothik.Cache, :get, [k])
  end
  def put(i, k, v) do
    :rpc.call(:"apothik_#{i}@127.0.0.1", Apothik.Cache, :put, [k, v])
  end
  def delete(i, k) do
    :rpc.call(:"apothik_#{i}@127.0.0.1", Apothik.Cache, :delete, [k])
  end
  def fill(i, n) do
    Enum.each(1..n, fn j -> put(i, "k_#{i}_#{j}", j) end)
  end
end
```

Relancez le cluster. Vérifions que l'on peut mettre des choses en cache sur un noeud donné:
```
% ./scripts/start_master.sh
1> Master.fill(1,1000)
:ok
2> Master.stat(1)
1000
```

Voilà, maintenant nous avons 5 caches sur 5 machines. La prochaine étape est d'avoir **un seul** cache **distribué** sur 5 machines!

### Le plan d'ensemble

Pour que le cluster se comporte comme un seul cache, il faut que l'on répartisse le stockage le plus uniformément possible sur chacun des 5 noeuds. Un couple {clé, valeur} sera alors présent sur un seul des noeuds.

De plus, nous souhaitons pouvoir interroger n'importe quel noeud du cluster pour obtenir une valeur. Nous ne voulons pas qu'un noeud spécialisé joue le rôle de point d'entrée particulier.

Nous devons donc résoudre deux questions:  comment envoyer un message à un processus situé sur un autre noeud et comment savoir que telle clé est sur tel serveur.

### Envoyer un message à un autre noeud

Il a fallu fouiller un peu. Une première idée est d'aller voir la documentation de [`Process`](https://hexdocs.pm/elixir/Process.html). 
Cela semble prometteur, la fonction fondamentale [`Process.send/3`](https://hexdocs.pm/elixir/Process.html#send/3) permet d'envoyer un message à partir 
de la connaissance du nom du process (local à la machine virtuelle) et du nom du noeud:  `Process.send({name_of_the_process, node_name}, msg, options)`.

Avant de faire un test d'envoi de message au cache, rajoutons quelques lignes dans `cache/cache.ex`
```elixir
  @impl true
  def handle_info(msg, state) do
    IO.inspect(msg)
    {:noreply, state}
  end
```
En effet, si l'on envoie un message quelconque à un `GenServer` (un message qui ne soit pas un `call` ou un `cast` par exemple), le callback `handle_info` est appelé.

Essayons:
``` 
% ./scripts/start_master.sh
1> Process.send({Apothik.Cache, :"apothik_1@127.0.0.1"}, "hey there", [])
:ok
```

Et `"hey there"` apparaît dans le terminal du cluster. Allez, on tente avec `GenServer.call`:

```
2>GenServer.call({Apothik.Cache, :"apothik_1@127.0.0.1"}, {:put, 1, "something"})
:ok
3> GenServer.call({Apothik.Cache, :"apothik_1@127.0.0.1"}, :stats)
1
4> GenServer.call({Apothik.Cache, :"apothik_1@127.0.0.1"}, {:get,1})
"something"
```

Visiblement, c'est le même fonctionnement avec `GenServer.call/3`! Ca y est, nous avons la première pièce manquante.

### Envoyer le message sur le bon noeud, à partir de n'importe quel noeud

Dans `cache/cache.ex`, on transforme les appels d'interface en, par exemple: 
```elixir
def get(k) do
  node = key_to_node(k)
  GenServer.call({__MODULE__, node}, {:get, k})
end
```
Supposons que `key_to_node` indique sur quel noeud est stocké la clé.
Si j'appelle la fonction `Apothik.Cache.get("a_key")` (par exemple en faisant `:rpc.call(:"apothik_1@127.0.0.1", Apothik.Cache, :get, ["a_key"]))`), et que `key_to_node("a_key)` renvoie `:"apothik_1@127.0.0.1"`, alors un message partira de `apothik_1` vers `apothik_2` puis reviendra en réponse de `apothik_2` vers `apothik_1` avec la réponse. On voit donc que tous les noeuds du cluster jouent le même rôle et peuvent répondre à toutes les requêtes.

### La fonction de hashing

La clé (jeu de mot!) de la solution est d'utiliser une méthode de hashing.  Une méthode de hashing est une fonction mathématique déterministe qui prend une chaine binaire (donc un nombre arbitrairement grand) et qui renvoie un nombre entier dans un intervalle fixe (qui peut être petit ou grand, selon les applications). Ces fonctions possèdent aussi des propriétés bien choisies. Par exemple, la propriété que deux nombres très voisins en entrée vont donner des résultats très différents en sortie. Et que l'intervalle de sortie est bien "balayé": mathématiquement, tous les éléments de l'ensemble d'arrivée ont des nombres d'antécédents comparables.

Erlang propose une méthode de hashing bien commode [`:erlang.phash2/2`](https://www.erlang.org/doc/apps/erts/erlang.html#phash2/2). Elle existe avec 1 ou 2 arguments. Avec deux arguments, les valeurs de sorties sont dans l'intervalle 0..argument.

Essayons:
```
% iex
iex(1)> :erlang.phash2(1)
2614250
iex(2)> :erlang.phash2(2)
27494836
iex(3)> :erlang.phash2(2,10)
8
iex(4)> :erlang.phash2(1,10)
2
iex(5)> (for i<-1..1000, do: :erlang.phash2(i, 5)) |> Enum.frequencies
%{0 => 214, 1 => 179, 2 => 207, 3 => 209, 4 => 191}
iex(6)> (for i<-1..100_000, do: :erlang.phash2(i, 5)) |> Enum.frequencies
%{0 => 20002, 1 => 20054, 2 => 20130, 3 => 19943, 4 => 19871}
```

On voit que les valeurs de sortie sont bien réparties de 0 à 4.

### Répartir les clés sur les serveurs

D'abord, faisons un peu le ménage. On rassemble la connaissance du cluster dans un module spécialisé: `apothik/cluster.ex`
```elixir
defmodule Apothik.Cluster do
  @nb_nodes 5

  def nb_nodes(), do: @nb_nodes

  def node_name(i), do: :"apothik_#{i}@127.0.0.1"

  def node_list() do
    for i <- 1..nb_nodes(), do: node_name(i)
  end
end
```

Cela change l'appel dans `apothik/application.ex`
```elixir
-    hosts = for i <- 1..5, do: :"apothik_#{i}@127.0.0.1"
+    hosts = Apothik.Cluster.node_list()
```

Tout est prêt pour implémenter `key_to_node/1` dans `cache/cache.ex`
```elixir
defmodule Apothik.Cache do
  use GenServer
  alias Apothik.Cluster

  # Interface
  def get(k) do
    node = key_to_node(k)
    GenServer.call({__MODULE__, node}, {:get, k})
  end

  def put(k, v) do
    node = key_to_node(k)
    GenServer.call({__MODULE__, node}, {:put, k, v})
  end

  def delete(k) do
    node = key_to_node(k)
    GenServer.call({__MODULE__, node}, {:delete, k})
  end

  def stats(), do: GenServer.call(__MODULE__, :stats)

  def start_link(args), do: GenServer.start_link(__MODULE__, args, name: __MODULE__)

  # Implementation

  defp key_to_node(k) do
    (:erlang.phash2(k, Cluster.nb_nodes()) + 1) |> Cluster.node_name()
  end

  (... same as before...)
end
```

La fonction est très simple: la clé donne un numéro de noeud entre 0 et 4, et on trouve le nom du cluster à partir de là.
On n'est pas très fier de la fonction `def node_name(i), do: :"apothik_#{i}@127.0.0.1"` qui pourrait allouer trop d'atomes (peut-être, pas sûr, il faudrait creuser mais ça n'est pas l'objet de cette phase).

Maintenant, remplissons le cache pour voir ce qui se passe:
```
% ./scripts/start_master.sh
1> Master.fill(1, 5000)
:ok
2> for i<-1..5, do: Master.stat(i)
[1026, 996, 1012, 1021, 945]
3> (for i<-1..5, do: Master.stat(i)) |> Enum.sum
5000
```

On a envoyé 5000 valeurs dans le cache distribué via le noeud 1. On constate que les valeurs ont bien été distribuées assez uniformément sur les 5 noeuds. 

Nous avons un cache distribué sur 5 machines ! Phase 1 accomplie !

<a href="/apothik/">Accueil</a>
<a href="fr_story_phase2.html"> Partie 2</a>
<a href="fr_story_phase3.html"> Partie 3</a>
