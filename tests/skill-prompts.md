# Example prompts for the server-ops skill (item 55)

For checking that the skill triggers when it should and stays quiet when it shouldn't: try these
in a Claude Code session with the plugin installed (or in an eval later). `tests/test-skill.sh`
only checks this file's shape.

## Should trigger
- What's running on web1?
- Which sites on web1 have SSL certificates expiring soon?
- Provision web2 with PHP 8.4.
- Create shop.example.com on web1.
- Deploy shop.example.com from main.
- Deploy the latest commit of the api site to staging1.
- Give shop.example.com HTTPS.
- Delete old-shop.example.com from web1.
- The deploy timed out, is it still running on web1?
- Stop the provision job on web2.
- shop.example.com shows 502, why?
- Is web1 healthy? It feels slow.
- Show me the Laravel errors of shop.example.com on web1.
- Has anyone logged in to web2 over SSH today?
- Who's hammering shop.example.com right now?
- Which commit is live on shop.example.com, and when was it deployed?
- What files are in storage/logs of shop.example.com?
- Is web1 secure? Run a security check.
- How many PHP workers can web2 handle?

## Should not trigger
- Write a migration that adds a status column to orders.
- Why does this PHPUnit test fail?
- Explain what an nginx location block does.
- Commit my changes with a good message.
- Set up a local .env for development.
- Add a Vue component for the checkout page.
