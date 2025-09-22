# Rails + Tailwind + Vite/React/TS + Devise + Pundit + Sidekiq + PaperTrail, etc.
#
# Usage:
#   rails new CHANGE_THIS_TO_YOUR_RAILS_APP_NAME \
#     -d postgresql --css tailwind -m ./rails_vite_template.rb
#
# This template:
# - Adds Devise (User), Simple Form (Tailwind), Pages#home, flashes
# - Installs Pundit, PaperTrail, Sidekiq (+ /sidekiq UI), Rack::Attack, Lograge
# - Sets up Vite + React + TypeScript (with a tiny React mount)
# - Generates a generic README titled with your app’s name (includes Option A/B usage)
# - Creates a **private GitHub repo** via GitHub CLI `gh` (if available), sets remote, and pushes

# --- Helpers -----------------------------------------------------------------
def safe_run(cmd)
  say_status :run, cmd, :cyan
  run cmd
rescue => e
  say_status :warn, "Command failed (continuing): #{e.message}", :yellow
end

def append_once(file, content)
  unless File.exist?(file) && File.read(file).include?(content.strip)
    append_file file, content
  end
end

def app_const_name
  base = File.basename(Dir.pwd).gsub(/[^a-zA-Z0-9_]/, "_")
  base.split("_").map { |p| p.capitalize }.join
end

def app_display_name
  base = File.basename(Dir.pwd).gsub(/[^a-zA-Z0-9_]/, " ")
  base.split(/\s+/).map { |p| p.capitalize }.join(" ")
end

APP_CONST = app_const_name
APP_TITLE = app_display_name

# Kill spring on mac (prevents template oddities)
safe_run "if uname | grep -q 'Darwin'; then pgrep spring | xargs kill -9 >/dev/null 2>&1 || true; fi"

# --- Gemfile -----------------------------------------------------------------
inject_into_file "Gemfile", before: "group :development, :test do" do
  <<~RUBY
    gem "devise"
    gem "simple_form", github: "heartcombo/simple_form"
    gem "dotenv-rails"
    gem "pundit"
    gem "paper_trail"
    gem "sidekiq"
    gem "redis"
    gem "ruby-openai", "~> 5.2"
    gem "aasm"
    gem "acts_as_tenant"
    gem "rack-attack"
    gem "oj"
    gem "mini_racer"
    gem "json_schemer"
    gem "lograge"
    gem "vite_rails"
  RUBY
end

# --- Layout & Flashes --------------------------------------------------------
gsub_file(
  "app/views/layouts/application.html.erb",
  '<meta name="viewport" content="width=device-width,initial-scale=1">',
  '<meta name="viewport" content="width=device-width, initial-scale=1, shrink-to-fit=no">'
)

file "app/views/shared/_flashes.html.erb", <<~HTML
  <% if notice %>
    <div class="m-2 rounded bg-blue-50 px-4 py-3 text-blue-800"><%= notice %></div>
  <% end %>
  <% if alert %>
    <div class="m-2 rounded bg-yellow-50 px-4 py-3 text-yellow-800"><%= alert %></div>
  <% end %>
HTML

inject_into_file "app/views/layouts/application.html.erb", after: "<body>" do
  <<~ERB
    <%= render "shared/flashes" %>
  ERB
end

# --- Generators & General Config ---------------------------------------------
environment <<~RUBY
  config.generators do |generate|
    generate.assets false
    generate.helper false
    generate.test_framework :test_unit, fixture: false
  end
RUBY

environment <<~RUBY
  config.action_controller.raise_on_missing_callback_actions = false if Rails.version >= "7.1.0"
RUBY

# --- After bundle -------------------------------------------------------------
after_bundle do
  # DB reset (fresh schema)
  rails_command "db:drop db:create db:migrate"

  # Simple Form (Tailwind wrappers)
  generate "simple_form:install", "--tailwind"

  # Static page
  generate :controller, "pages", "home", "--skip-routes", "--no-test-framework"
  route 'root to: "pages#home"'

  # .gitignore & dotenv
  append_once ".gitignore", <<~TXT
    .env*
    .DS_Store
    *.swp
  TXT
  safe_run "touch .env"

  # Devise
  generate "devise:install"
  generate "devise", "User"

  # Require auth by default
  remove_file "app/controllers/application_controller.rb"
  file "app/controllers/application_controller.rb", <<~RUBY
    class ApplicationController < ActionController::Base
      before_action :authenticate_user!
    end
  RUBY

  rails_command "db:migrate"
  generate "devise:views"

  # Allow home without auth
  remove_file "app/controllers/pages_controller.rb"
  file "app/controllers/pages_controller.rb", <<~RUBY
    class PagesController < ApplicationController
      skip_before_action :authenticate_user!, only: [:home]
      def home; end
    end
  RUBY

  # Mailer hosts
  environment 'config.action_mailer.default_url_options = { host: "http://localhost:3000" }', env: "development"
  environment 'config.action_mailer.default_url_options = { host: "http://TODO_PUT_YOUR_DOMAIN_HERE" }', env: "production"

  # --- Pundit ----------------------------------------------------------------
  generate "pundit:install"
  # Insert Pundit hooks into ApplicationController
  gsub_file "app/controllers/application_controller.rb",
            "class ApplicationController < ActionController::Base\n",
            <<~RUBY
              class ApplicationController < ActionController::Base
                include Pundit::Authorization
                before_action :authenticate_user!

                rescue_from Pundit::NotAuthorizedError, with: :user_not_authorized

                private

                def user_not_authorized
                  redirect_to(request.referrer || root_path, alert: "Not authorized.")
                end
            RUBY

  # --- PaperTrail ------------------------------------------------------------
  generate "paper_trail:install"
  rails_command "db:migrate"

  # --- Sidekiq ---------------------------------------------------------------
  file "config/initializers/sidekiq.rb", <<~RUBY
    Sidekiq.configure_server do |config|
      config.redis = { url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0") }
    end
    Sidekiq.configure_client do |config|
      config.redis = { url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0") }
    end
  RUBY

  # Mount Sidekiq web UI for authenticated users
  append_to_file "config/routes.rb", <<~RUBY

    require "sidekiq/web"
    authenticate :user do
      mount Sidekiq::Web => "/sidekiq"
    end
  RUBY

  # --- Rack::Attack ----------------------------------------------------------
  file "config/initializers/rack_attack.rb", <<~RUBY
    class Rack::Attack
      throttle("req/ip", limit: 300, period: 5.minutes) { |req| req.ip }
    end
  RUBY

  gsub_file "config/application.rb",
            "class Application < Rails::Application\n",
            "class Application < Rails::Application\n    config.middleware.use Rack::Attack\n"

  # --- Lograge ---------------------------------------------------------------
  append_once "config/environments/production.rb", "\nconfig.lograge.enabled = true\n"

  # --- Vite + React + TS -----------------------------------------------------
  rails_command "vite:install"

  entrypoint_js = "app/frontend/entrypoints/application.js"
  entrypoint_tsx = "app/frontend/entrypoints/application.tsx"

  if File.exist?(entrypoint_js)
    gsub_file entrypoint_js, /\A[\s\S]*\z/, <<~JS
      import React from "react";
      import { createRoot } from "react-dom/client";
      import App from "../App";

      document.addEventListener("DOMContentLoaded", () => {
        const el = document.getElementById("react-root");
        if (el) createRoot(el).render(<App />);
      });
    JS
  elsif File.exist?(entrypoint_tsx)
    gsub_file entrypoint_tsx, /\A[\s\S]*\z/, <<~TSX
      import React from "react";
      import { createRoot } from "react-dom/client";
      import App from "../App";

      document.addEventListener("DOMContentLoaded", () => {
        const el = document.getElementById("react-root");
        if (el) createRoot(el).render(<App />);
      });
    TSX
  else
    file entrypoint_js, <<~JS
      import React from "react";
      import { createRoot } from "react-dom/client";
      import App from "../App";

      document.addEventListener("DOMContentLoaded", () => {
        const el = document.getElementById("react-root");
        if (el) createRoot(el).render(<App />);
      });
    JS
  end

  # Initialize TS & React
  safe_run "npm i -D react react-dom @types/react @types/react-dom typescript"
  safe_run "npx tsc --init --jsx react-jsx --esModuleInterop --resolveJsonModule --skipLibCheck"

  # Provide a basic React mount point (optional)
  empty_directory "app/frontend"
  file "app/frontend/App.tsx", <<~TSX
    import * as React from "react";
    export default function App() {
      return <div className="p-6 text-xl font-semibold">Hello from React + Vite + Tailwind</div>;
    }
  TSX

  # Inject mount node into layout body
  gsub_file "app/views/layouts/application.html.erb",
            "<body>",
            "<body>\n    <div id=\"react-root\"></div>"

  # --- README (generic, uses your app's name; includes Option A & B) ----------
  file "README.md", <<~MD, force: true
    # #{APP_TITLE}

    A Rails 7 application template that bootstraps a modern stack with authentication, authorization, background jobs, auditing, and frontend tooling.

    ---

    ## 🚀 Usage

    ### Option A — apply template directly (requires public access)

    ```bash
    rails new \\
      -d postgresql \\
      -c tailwind \\
      -m https://raw.githubusercontent.com/AzCez/rails_template/main/rails_vite_template.rb \\
      CHANGE_THIS_TO_YOUR_RAILS_APP_NAME
    ```

    ### Option B — download then apply locally (works for private repos)

    ```bash
    curl -fsSL -o rails_vite_template.rb \\
      https://raw.githubusercontent.com/AzCez/rails_template/7ee76a4f70e152c119cf67dce832b15a5e318210/rails_vite_template.rb

    bin/rails app:template LOCATION=./rails_vite_template.rb
    ```

    > Tip: If your template repository is private, **Option B** avoids 404 errors from raw.githubusercontent.com.

    ---

    ## ✨ What this template does

    - **Authentication & Accounts**
      - Adds Devise (`User` model)
      - Tailwind-styled Devise views
      - Simple Form with Tailwind wrappers
      - Flash messages (notice/alert)

    - **Authorization & Policies**
      - Installs Pundit
      - Default `before_action :authenticate_user!`

    - **Background Jobs**
      - Sidekiq + Redis integration
      - Web UI mounted at `/sidekiq` (requires login)

    - **Audit & Logging**
      - PaperTrail for record versioning
      - Lograge for structured logging

    - **Security**
      - Rack::Attack for rate limiting

    - **Frontend**
      - TailwindCSS (Rails 7 `--css tailwind`)
      - Vite + React + TypeScript setup
      - Example `App.tsx` mounted at `#react-root`

    - **Project setup**
      - Generates this generic `README.md` titled with your app’s name
      - Initializes Git and (optionally) a private GitHub repo via `gh` if available

    ---

    ## 🛠️ Requirements

    - Ruby 3.2+
    - Rails 7.1+
    - PostgreSQL 14+
    - Redis 6+
    - Node.js 18+ & Yarn/NPM
    - Foreman (`gem install foreman`) for `bin/dev`

    ---

    ## 🧪 Getting started

    ```bash
    bundle install
    yarn install   # or: npm install
    bin/rails db:setup
    ```

    Start dev servers (Rails + Vite):
    ```bash
    bin/dev
    ```

    Visit:
    - http://localhost:3000 → Rails app
    - http://localhost:3000/sidekiq → Sidekiq dashboard (requires login)

    ---

    ## 🔑 Authentication

    Devise provides:
    - `User` model with email/password
    - Registration, login, password recovery
    - Root page (`/`) is public, all others require login

    Create your first user:

    ```bash
    bin/rails console
    User.create!(email: "admin@example.com", password: "password123", password_confirmation: "password123")
    ```

    ---

    ## 📦 Project Structure

    ```
    app/
      controllers/      # Devise, PagesController, ApplicationController
      models/           # User + (extend with Tenant, etc.)
      views/            # Devise views (Tailwind-ready), pages/home
      frontend/         # React components (App.tsx entry)
    config/
      initializers/     # Sidekiq, Rack::Attack, etc.
      routes.rb         # Root route + /sidekiq
    ```

    ---

    ## 📚 Development Notes

    - **Policies:** Add Pundit policies under `app/policies/`.
    - **Multi-tenancy:** Add a `Tenant` model and associate with `User` to enable scoped data.
    - **Service objects:** Put business logic in `app/services/`.
    - **Background jobs:** Use `Sidekiq::Worker` classes under `app/workers/`.

    ---

    ## ✅ Next Steps

    1. Add your domain models.
    2. Build services/workers for your business logic.
    3. Secure endpoints with Pundit policies.
    4. Deploy with Redis and a Sidekiq worker process.

    ---

    ## 🔗 GitHub repo auto-creation (optional)

    If you have GitHub CLI installed and authenticated, the template can create a **private repo** and push the initial commit automatically.

    ```bash
    gh auth login
    export GITHUB_OWNER=your-org-or-username   # optional
    ```

    ---

    ## 📜 License

    MIT — use and adapt for your projects.
  MD

  # --- Rubocop (optional) ----------------------------------------------------
  safe_run "curl -L https://raw.githubusercontent.com/lewagon/rails-templates/master/.rubocop.yml > .rubocop.yml"

  # --- Git & GitHub ----------------------------------------------------------
  git :init
  safe_run "git add ."
  safe_run %Q{git commit -m "Initial commit: #{APP_TITLE} (Rails + Tailwind + Vite/React/TS + Devise + Pundit + Sidekiq + PaperTrail) template"}
  safe_run "git branch -M main"

  # Create a private GitHub repo and push (requires GitHub CLI: https://cli.github.com/)
  repo_name = File.basename(Dir.pwd)
  owner     = ENV["GITHUB_OWNER"] # optional, e.g., "your-org" or "your-username"
  gh_exists = system("which gh > /dev/null 2>&1")

  if gh_exists
    say_status :info, "Creating private GitHub repo via `gh`...", :green
    if owner && !owner.strip.empty?
      # Create under specific owner
      safe_run %Q{gh repo create "#{owner}/#{repo_name}" --private --source=. --remote=origin --push}
    else
      # Create under authenticated user
      safe_run %Q{gh repo create "#{repo_name}" --private --source=. --remote=origin --push}
    end
  else
    say_status :warn, "GitHub CLI not found; skipping auto repo creation. Install gh: https://cli.github.com/", :yellow
    # If remote not set, print a hint
    unless `git remote`.include?("origin")
      say_status :hint, "You can set the remote and push manually:", :blue
      say_status :hint, "  git remote add origin git@github.com:#{owner ? "#{owner}/" : ""}#{repo_name}.git", :blue
      say_status :hint, "  git push -u origin main", :blue
    end
  end
end
