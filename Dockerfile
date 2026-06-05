# syntax = docker/dockerfile:1

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version and Gemfile
ARG RUBY_VERSION=3.4.7
FROM registry.docker.com/library/ruby:$RUBY_VERSION-slim AS base

# Rails app lives here
WORKDIR /rails

# Install base packages
RUN apt-get update -qq \
    && apt-get install --no-install-recommends -y curl libvips postgresql-client libyaml-0-2 procps \
    && rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Set production environment
ARG BUILD_COMMIT_SHA
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development" \
    BUILD_COMMIT_SHA=${BUILD_COMMIT_SHA}
    
# Throw-away build stage to reduce size of final image
FROM base AS build

# Install packages needed to build gems and the Vite frontend (Node 24 + npm)
ARG NODE_MAJOR=24
RUN apt-get update -qq \
    && apt-get install --no-install-recommends -y build-essential libpq-dev git pkg-config libyaml-dev ca-certificates gnupg \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" > /etc/apt/sources.list.d/nodesource.list \
    && apt-get update -qq \
    && apt-get install --no-install-recommends -y nodejs \
    && rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Install application gems
COPY .ruby-version Gemfile Gemfile.lock ./
RUN bundle install \
    && rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git \
    && bundle exec bootsnap precompile --gemfile -j 0

# Install JS dependencies for the Vite build (reproducible from the lockfile)
COPY package.json package-lock.json ./
RUN npm ci

# Copy application code
COPY . .

# Precompile bootsnap code for faster boot times
RUN bundle exec bootsnap precompile -j 0 app/ lib/

# Precompiling assets for production without requiring secret RAILS_MASTER_KEY.
# This runs the Vite production build and emits compiled assets under public/vite.
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile

# Drop Node build dependencies so the final runtime image carries only the
# compiled Vite assets (public/vite) and never needs the Vite dev server.
RUN rm -rf node_modules

# Final stage for app image
FROM base

# Run and own only the runtime files as a non-root user for security
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
USER 1000:1000

# Copy built artifacts: gems, application
COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails

# Entrypoint prepares the database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Start the server by default, this can be overwritten at runtime
EXPOSE 3000
CMD ["./bin/rails", "server"]
