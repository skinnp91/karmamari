FROM ruby:2.6
RUN gem install bundler

ADD ./Gemfile /src/karmamari/Gemfile
WORKDIR /src/karmamari
RUN bundle install

ADD . /src/karmamari

ENTRYPOINT ["ruby", "karmamari.rb"]
