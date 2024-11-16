---
layout: home
---
# Documents
<ul>
  {% for page in site.pages %}
    {% if page.path contains 'stories/' %}
      <li>
        <a href="{{ page.url | relative_url }}">{{ page.title }}</a>
      </li>
    {% endif %}
  {% endfor %}
</ul>

