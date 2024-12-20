---
layout: home
---


<p>Voici une série de 3 articles qui racontent notre chemin de découverte de la difficulté des applications distribuées. Les articles sont en français ou en anglais.</p>
<p>Here is a series of 3 articles that tell our journey of discovering the challenges of distributed applications. The articles are in French or English.</p>
<ul>
  {% for page in site.pages %}
    {% if page.path contains 'stories/' %}
      <li>
        <a href="{{ page.url | relative_url }}">{{ page.title }}</a>
      </li>
    {% endif %}
  {% endfor %}
</ul>

