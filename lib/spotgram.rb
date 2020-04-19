require "spotgram/version"
require "telegram/bot"
require 'open3'
require 'concurrent-ruby'

module Spotgram
  class Threadpool
    def initialize(num_workers)
      @semaphore ||= Concurrent::Semaphore.new(num_workers)
    end

    def execute
      @semaphore.acquire
      Thread.new do
        begin
          yield
        ensure
          @semaphore.release
        end
      end
    end
  end

  class Bot
    LINKS_RE = /(^(http|https):\/\/[a-z0-9]+([\-\.]{1}[a-z0-9]+)*\.[a-z]{2,5}(([0-9]{1,5})?\/.*)?$)/ix
    STORAGE = "#{ENV['HOME']}/.spotgram"

    def initialize(api_key, mirror_to_chat_id: nil)
      @api_key = api_key
      @mirror_to_chat_id = mirror_to_chat_id

      unless File.directory?(STORAGE)
        Dir.mkdir(STORAGE)
      end
    end

    def run
      STDOUT.sync = true

      Thread.new do
        one_hour = 60 * 60
        last_update = 0
        loop do
          time_since_update = Time.now.to_i - last_update
          if time_since_update > one_hour
            upgrade_ytdl
            last_update = Time.now.to_i
          end
          sleep 5
        end
      end

      threadpool = Threadpool.new(8)
      Telegram::Bot::Client.run(@api_key) do |bot|
        bot.listen do |message|
          ctx = Context.new(bot, message)

          begin
            case message.text
            when '/start'
              puts "[Access Log] joined: username=#{message.from.username} first_name=#{message.from.first_name}"
              txt = "Hello, #{message.from.first_name}. Send me any Spotify/Youtube/SoundCloud link and I'll convert it to mp3. You can even share it directly from the apps"
              bot.api.send_message(chat_id: message.chat.id, text: txt)
              if @mirror_to_chat_id
                bot.api.send_message(chat_id: @mirror_to_chat_id, text: "New user: @#{message.from.username}")
              end
            else
              threadpool.execute do
                puts "[Access Log] received: username=#{message.from.username} text=#{message.text}"
                handle_message(ctx)
              end
            end
          rescue => e
            puts "Rescued exception while handling message=#{message}: #{e}"
          end
        end
      end
    end

    private

    Context = Struct.new(
      :bot,
      :message,
      :last_msg,
      :filename,
      :ytdl_link,
      :spotify_link,
      :artist,
      :track,
      :link_title,
      :song_info_page,
    )

    def handle_message(ctx)
      new_text_msg(ctx, "🔎 Searching for song...\n\nTip: I accept spotify/youtube/soundcloud links")

      query_link = extract_query_link(ctx.message.text)
      return set_progress_txt(ctx, "😔 Couldn't find any link there") if query_link.nil?

      if query_link.match(/instagram/)
        return handle_video(ctx, query_link)
      elsif query_link.match(/spotify/)
        ctx.spotify_link = query_link
        return set_progress_txt(ctx, "😔 Not supported yet. Share tracks instead of albums") if query_link.match(/album/)

        ctx.ytdl_link = spotify_to_ytdl(ctx)
        return new_text_msg(ctx, "😔 Couldnt find the youtube link. Try pasting a youtube link?") unless ctx.ytdl_link
      else
        ctx.ytdl_link = query_link
      end

      handle_ytdl_track(ctx)
    end

    def handle_ytdl_track(ctx)
      download_metadata(ctx)

      ctx.song_info_page = "\n\nOriginal Link: #{ctx.ytdl_link}"
      ctx.song_info_page += "\nOriginal Title: #{ctx.link_title}" if ctx.link_title
      ctx.song_info_page += "\nSong Arist: #{ctx.artist}" if ctx.artist
      ctx.song_info_page += "\nSong Title: #{ctx.track}" if ctx.track

      set_progress_txt(ctx, "🏃‍♀️ Converting to audio file" + ctx.song_info_page)

      handle_generic_ytdl(ctx)
    end

    def handle_generic_ytdl(ctx)
      download_ytdl_audio(ctx)

      if ctx.filename
        set_progress_txt(ctx, "💈 Uploading file" + ctx.song_info_page)

        send_audio(ctx, ctx.filename, title: ctx.track, performer: ctx.artist)
        set_progress_txt(ctx, "📻 See you later" + ctx.song_info_page)
      else
        new_text_msg(ctx, "😔 Couldnt download that link, sorry")
      end
    end

    def download_metadata(ctx)
      cmd = [
        "youtube-dl",
        "-j",
        ctx.ytdl_link,
      ]

      stdout, stderr, status = Open3.capture3(*cmd)
      if status.success?
        begin
          yt_metadata = JSON.parse(stdout)
        rescue
          puts "couldn't parse metadata for #{ctx.ytdl_link}"
          return
        end

        case yt_metadata['extractor']
        when "youtube"
          ctx.artist = yt_metadata['artist']
          ctx.track = yt_metadata['track']
          ctx.link_title = yt_metadata['title']
        when "soundcloud"
          ctx.artist = yt_metadata['uploader']
          ctx.track = yt_metadata['title']
          ctx.link_title = yt_metadata['fulltitle']
        end
      else
        puts "error downloading metadata"
        puts stdout, stderr
      end

    end

    def new_text_msg(ctx, text)
      msg = ctx.bot.api.send_message(chat_id: ctx.message.chat.id, text: text)
      ctx.last_msg = msg if msg['ok']
    end

    def set_progress_txt(ctx, text)
      ctx.bot.api.edit_message_text(
        chat_id: ctx.message.chat.id,
        message_id: ctx.last_msg['result']['message_id'],
        text: text,
        disable_web_page_preview: true
      )
    end

    def send_audio(ctx, filename, **args)
      begin
        msg = ctx.bot.api.send_audio(**args, chat_id: ctx.message.chat.id, audio: Faraday::UploadIO.new(filename, 'audio/mp3'))
        unless msg['ok'] && msg['result']['audio']['file_id']
          puts "Couldnt forward to archives chat msg=#{msg}"
          return
        end

        if @mirror_to_chat_id
          ctx.bot.api.send_audio(**args, chat_id: @mirror_to_chat_id,
            audio: msg['result']['audio']['file_id'],
            caption: "From #{ctx.message.from.first_name} (@#{ctx.message.from.username})"
          )
        end
      rescue Telegram::Bot::Exceptions::ResponseError
        set_progress_txt(ctx, "Couldn't upload that file.")
        raise
      end
    end

    def send_video_file(ctx, filename, **args)
      begin
        msg = ctx.bot.api.send_video(**args, chat_id: ctx.message.chat.id, video: Faraday::UploadIO.new(filename, 'video/mp4'))
        unless msg['ok'] && msg['result']['video']['file_id']
          puts "Couldnt forward to archives chat msg=#{msg}"
          return
        end

        if @mirror_to_chat_id
          ctx.bot.api.send_video(**args, chat_id: @mirror_to_chat_id,
            video: msg['result']['video']['file_id'],
            caption: "From #{ctx.message.from.first_name} (@#{ctx.message.from.username})"
          )
        end
      rescue Telegram::Bot::Exceptions::ResponseError
        set_progress_txt(ctx, "Couldn't upload that file.")
        raise
      end
    end

    def extract_query_link(msg)
      matches = msg.match(LINKS_RE)
      return matches && matches[0].split(" ")[0]
    end

    def spotify_to_ytdl(ctx)
      return if ctx.ytdl_link

      spotify_link = ctx.spotify_link
      cmd = [
        "spotdl",
        "-d",
        "-s",
        spotify_link
      ]

      _, stderr, status = Open3.capture3(*cmd)
      if status.success?
        matches = stderr.match(/(http.*)\)/)
        return matches && matches[1]
      end
    end

    def get_ytdl_filename(ytdl_link, format: "mp3")
      stdout, stderr, status = Open3.capture3(
        "youtube-dl",
        "--get-filename",
        "-o",
        "./tmp/downloads/%(title)s.#{format == :auto ? "%(ext)s": format}",
        ytdl_link
      )

      if status.success?
        return stdout.chomp
      else
        puts "failed to get filename"
        puts stdout, stderr
      end
    end

    def progress_indicator(ctx, text)
      random_emoji = ["😀","😁","😂","😃","😄","😅","😆","😇","😈","👿","😉",
                    "😊","☺️","😋","😌","😍","😎","😏","😐","😑","😒","😓",
                    "😔","😕","😖"].sample
      set_progress_txt(ctx, "#{random_emoji} #{text}" + ctx.song_info_page)
    rescue => e
      puts "WARN: #{e}"
    end

    def download_ytdl_audio(ctx)
      ytdl_link = ctx.ytdl_link
      output_filename = get_ytdl_filename(ytdl_link)
      return unless output_filename

      stdin, stdouts, wait_thr = Open3.popen2e(
        "youtube-dl",
        "--extract-audio",
        "--continue",
        "--no-post-overwrites",
        "--no-overwrites",
        "--no-playlist",
        "--ignore-errors",
        "--add-metadata",
        "--audio-format",
        "mp3",
        "--audio-quality",
        "0",
        "--no-mtime",
        "-o",
        "./tmp/downloads/%(title)s.%(ext)s",
        ytdl_link,
      )
      stdin.close

      start_time = Time.now.to_i
      while wait_thr.alive?
        progress_indicator(ctx, "Downloading audio file..")
        sleep 2

        elapsed = Time.now.to_i - start_time
        if elapsed > 5 * 60
          Process.kill("KILL",wait_thr.pid)
          new_text_msg(ctx, "😔 That took a long time. Gave up")
        end
      end

      if wait_thr.value.success?
        puts "downloaded successfully"
        ctx.filename = output_filename
      else
        puts "failed to download"
        puts stdouts.read
      end
    ensure
      stdouts&.close
    end

    def handle_video(ctx, link)
      ctx.song_info_page = "\n\nOriginal Video: #{link}"
      set_progress_txt(ctx, "🏃‍♀️ Downloading video.." + ctx.song_info_page)

      output_filename = get_ytdl_filename(link, format: :auto)
      return unless output_filename

      stdin, stdouts, wait_thr = Open3.popen2e(
        "youtube-dl",
        "--continue",
        "--no-post-overwrites",
        "--no-overwrites",
        "--no-playlist",
        "--ignore-errors",
        "--no-mtime",
        "-o",
        "./tmp/downloads/%(title)s.%(ext)s",
        link,
      )
      stdin.close

      start_time = Time.now.to_i
      while wait_thr.alive?
        progress_indicator(ctx, "Downloading video file..")
        sleep 2

        elapsed = Time.now.to_i - start_time
        if elapsed > 5 * 60
          Process.kill("KILL",wait_thr.pid)
          new_text_msg(ctx, "😔 That took a long time. Gave up")
        end
      end

      if wait_thr.value.success?
        puts "downloaded #{link} successfully"
        set_progress_txt(ctx, "💈 Uploading file" + ctx.song_info_page)
        send_video_file(ctx, output_filename)
        set_progress_txt(ctx, "📻 See you later" + ctx.song_info_page)
      else
        puts "failed to download #{link}"
        puts stdouts.read
      end
    ensure
      stdouts&.close
    end

    def upgrade_ytdl
      puts "Attempting to upgrade youtube-dl"
      puts `youtube-dl -U`
    end
  end
end
