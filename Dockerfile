FROM ruby:3.2.2

RUN apt-get update -qq && apt-get install -y \
  build-essential \
  default-libmysqlclient-dev \
  nodejs \
  npm \
  yarn

WORKDIR /app

COPY Gemfile Gemfile.lock ./

RUN gem install bundler && bundle install

COPY . .

RUN npm install && npm install esbuild --global

RUN bundle exec rake assets:precompile

RUN rm -f /app/tmp/pids/server.pid

EXPOSE 3000

CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
