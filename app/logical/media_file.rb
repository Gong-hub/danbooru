# frozen_string_literal: true

# A MediaFile represents an image, video, or flash file. It contains methods for
# detecting the file type, for generating a preview image, for getting metadata,
# and for resizing images.
#
# A MediaFile is a wrapper around a File object, and supports all methods
# supported by a File.
class MediaFile
  extend Memoist
  include ActiveModel::Serializers::JSON

  attr_accessor :file, :strict

  # delegate all File methods to `file`.
  delegate *(File.instance_methods - MediaFile.instance_methods), to: :file

  # Open a file or filename and return a MediaFile object.
  #
  # @param file [File, String] a filename or an open File object
  # @param options [Hash] extra options for the MediaFile subclass.
  # @return [MediaFile] the media file
  def self.open(file, **options)
    return file.dup if file.is_a?(MediaFile)

    file = Kernel.open(file, "r", binmode: true) unless file.respond_to?(:read)

    case file_ext(file)
    when :jpg, :gif, :png, :webp, :avif
      MediaFile::Image.new(file, **options)
    when :swf
      MediaFile::Flash.new(file, **options)
    when :webm, :mp4
      MediaFile::Video.new(file, **options)
    when :zip
      MediaFile::Ugoira.new(file, **options)
    else
      MediaFile.new(file, **options)
    end
  end

  # Detect a file's type based on the magic bytes in the header.
  # @param [File] an open file
  # @return [Symbol] the file's type
  def self.file_ext(file)
    header = file.pread(16, 0)

    case header
    when /\A\xff\xd8/n
      :jpg
    when /\AGIF87a/, /\AGIF89a/
      :gif
    when /\A\x89PNG\r\n\x1a\n/n
      :png
    when /\ACWS/, /\AFWS/, /\AZWS/
      :swf

    # This detects the Matroska (.mkv) header. WebM files have a DocType of "webm", which is checked later in `MediaFile::Video#is_supported?`.
    #
    # https://www.rfc-editor.org/rfc/rfc8794.html#section-8.1
    # https://www.webmproject.org/docs/container/
    when /\A\x1a\x45\xdf\xa3/n
      :webm

    # https://developers.google.com/speed/webp/docs/riff_container
    when /\ARIFF....WEBP/
      :webp

    # https://www.ftyps.com
    # https://cconcolato.github.io/mp4ra/filetype.html
    # https://github.com/mozilla/gecko-dev/blob/master/toolkit/components/mediasniffer/nsMediaSniffer.cpp#L78
    # https://mimesniff.spec.whatwg.org/#signature-for-mp4
    #
    # isom (common) - MP4 Base Media v1 [IS0 14496-12:2003]
    # mp42 (common) - MP4 v2 [ISO 14496-14]
    # iso4 (rare) - MP4 Base Media v4
    # iso5 (rare) - MP4 Base Media v5 (used by Twitter)
    # 3gp5 (rare) - 3GPP Media (.3GP) Release 5 (XXX technically this should be .3gp, not .mp4. Supported by Chrome but not Firefox)
    # avc1 (rare) - MP4 Base w/ AVC ext [ISO 14496-12:2005]
    # M4V (rare) - Apple iTunes Video (https://en.wikipedia.org/wiki/M4V)
    when /\A....ftyp(?:mp4|avc|iso|3gp5|M4V)/
      :mp4

    # https://aomediacodec.github.io/av1-avif/#brands-overview
    when /\A....ftyp(?:avif|avis)/
      :avif
    when /\APK\x03\x04/
      :zip
    else
      :bin
    end
  rescue EOFError
    :bin
  end

  # @return [Boolean] true if we can generate video previews.
  def self.videos_enabled?
    system("ffmpeg -version > /dev/null") && system("mkvmerge --version > /dev/null")
  end

  # Initialize a MediaFile from a regular File.
  #
  # @param file [File] The image file.
  # @param strict [Boolean] If true, raise errors if the file is corrupt. If false,
  #   try to process corrupt files without raising any errors.
  def initialize(file, strict: true, **options)
    @file = file
    @strict = strict
  end

  # @return [Array<(Integer, Integer)>] the width and height of the file
  def dimensions
    [0, 0]
  end

  # @return [Integer] the width of the file
  def width
    dimensions.first
  end

  # @return [Integer] the height of the file
  def height
    dimensions.second
  end

  # @return [Integer] the resolution of the file
  def resolution
    width * height
  end

  # @return [String] the MD5 hash of the file, as a hex string.
  def md5
    Digest::MD5.file(file.path).hexdigest
  end

  # @return [Symbol] the detected file extension
  def file_ext
    MediaFile.file_ext(file)
  end

  # @return [Integer] the size of the file in bytes
  def file_size
    file.size
  end

  def metadata
    ExifTool.new(file).metadata
  end

  def mime_type
    Mime::Type.lookup_by_extension(file_ext)
  end

  # @return [Boolean] True if the file is supported by Danbooru. Certain files may be unsupported because they use features we don't support.
  def is_supported?
    true
  end

  # @return [Boolean] true if the file is an image
  def is_image?
    file_ext.in?(%i[jpg png gif webp avif])
  end

  # @return [Boolean] true if the file is a video
  def is_video?
    file_ext.in?([:webm, :mp4])
  end

  # @return [Boolean] True if the file is a MP4.
  def is_mp4?
    file_ext == :mp4
  end

  # @return [Boolean] True if the file is a WebM.
  def is_webm?
    file_ext == :webm
  end

  # @return [Boolean] true if the file is a Pixiv ugoira
  def is_ugoira?
    file_ext == :zip
  end

  # @return [Boolean] true if the file is a Flash file
  def is_flash?
    file_ext == :swf
  end

  # @return [Boolean] true if the file is corrupted in some way
  def is_corrupt?
    false
  end

  # @return [Boolean] true if the file is animated. Note that GIFs and PNGs may be animated.
  def is_animated?
    is_video? || frame_count.to_i > 1
  end

  # @return [Float, nil] the duration of the video or animation in seconds, or
  #   nil if not a video or animation, or the duration is unknown.
  def duration
    nil
  end

  # @return [Float, nil] the number of frames in the video or animation, or nil
  #   if not a video or animation.
  def frame_count
    nil
  end

  # @return [Float, nil] the average frame rate of the video or animation, or
  #   nil if not a video or animation. Note that GIFs and PNGs can have a
  #   variable frame rate.
  def frame_rate
    nil
  end

  # @return [Boolean] true if the file has an audio track. The track may not be audible.
  def has_audio?
    false
  end

  # Return a preview of the file, sized to fit within the given width and height (preserving the aspect ratio).
  #
  # @param width [Integer] the max width of the image
  # @param height [Integer] the max height of the image
  # @param options [Hash] extra options when generating the preview
  # @return [MediaFile, nil] a preview file, or nil if we can't generate a preview for this file type (e.g. Flash files)
  def preview(width, height, **options)
    preview!(width, height, **options)
  rescue
    nil
  end

  # Like `preview`, but raises an exception if generating the preview fails for any reason.
  def preview!(width, height, **options)
    raise NotImplementedError
  end

  # Return a set of AI-inferred tags for this image. Performs an API call to
  # the Autotagger service. The Autotagger service must be running, otherwise
  # it will return an empty list of tags.
  #
  # @return [Array<AITag>] The list of AI tags.
  def ai_tags(autotagger: AutotaggerClient.new)
    tags = autotagger.evaluate(self)

    tags.map do |tag, score|
      AITag.new(tag: tag, score: (100*score).round)
    end
  end

  def attributes
    {
      path: path,
      width: width,
      height: height,
      file_size: file_size,
      file_ext: file_ext,
      mime_type: mime_type,
      md5: md5,
      is_corrupt?: is_corrupt?,
      is_supported?: is_supported?,
      duration: duration,
      frame_count: frame_count,
      frame_rate: frame_rate,
      metadata: metadata
    }.stringify_keys
  end

  # Scale `width` and `height` to fit within `max_width` and `max_height`.
  def self.scale_dimensions(width, height, max_width, max_height)
    max_width ||= Float::INFINITY
    max_height ||= Float::INFINITY

    if width <= max_width && height <= max_height
      [width, height]
    else
      scale = [max_width.to_f / width.to_f, max_height.to_f / height.to_f].min
      [(width * scale).round.to_i, (height * scale).round.to_i]
    end
  end

  memoize :file_ext, :file_size, :md5, :metadata, :mime_type
end
