---
layout: home
---

<p>
Cette série de 3 articles a pour thème les **applications distribuées**. Elle est écrite par des débutants dans le domaine, et s'adresse à des **débutants**.
C'est le récit non censuré de notre tentative de commencer à en gratter la surface. Ce n'est pas un cours sur la programmation décentralisée. Les articles racontent notre chemin de découverte du monde complexe des applications distribuées.

Les articles sont en français ou en anglais (écrit d'abord en français et traduits automatiquement en anglais).

</p>

<p>
This series of 3 articles is about **distributed applications**. It is written by beginners in the field, and is aimed at **beginners**.
It is the uncensored account of our attempt to start scratching the surface. It is not a course on decentralized programming. The articles tell the story of our journey of discovery into the complex world of distributed applications.

The articles are in French or English (first written in French and automatically translated into English).

</p>

<ul>
  {% for page in site.pages %}
    {% if page.path contains 'stories/' %}
      <li>
        <a href="{{ page.url | relative_url }}">{{ page.title }}</a>
      </li>
    {% endif %}
  {% endfor %}
</ul>

