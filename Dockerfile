FROM ruby:2.7

# install mp3 converter and python
RUN apt-get update -qq && apt-get install -y ffmpeg python3 python3-pip

# install https://github.com/ritiek/spotify-downloader
RUN pip3 install spotdl

# install youtube-dl
RUN curl -L https://github.com/ytdl-org/youtube-dl/releases/latest/download/youtube-dl -o /usr/local/bin/youtube-dl
RUN chmod a+rx /usr/local/bin/youtube-dl

RUN mkdir /app
WORKDIR /app
COPY Gemfile /app/Gemfile
COPY Gemfile.lock /app/Gemfile.lock
RUN bundle install

COPY . /app

# Add a script to be executed every time the container starts.
COPY entrypoint.sh /usr/bin/
RUN chmod +x /usr/bin/entrypoint.sh

RUN addgroup --gid 1024 spotgroup
RUN adduser --disabled-password --gecos "" --force-badname --ingroup spotgroup spotuser

# Start the main process.
CMD ["ruby", "/app/exe/spotgram"]
