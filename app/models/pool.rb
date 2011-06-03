class Pool < ActiveRecord::Base
  validates_uniqueness_of :name
  validates_format_of :name, :with => /\A[^\s;,]+\Z/, :on => :create, :message => "cannot have whitespace, commas, or semicolons"
  belongs_to :creator, :class_name => "User"
  belongs_to :updater, :class_name => "User"
  has_many :versions, :class_name => "PoolVersion", :dependent => :destroy, :order => "pool_versions.id ASC"
  before_validation :normalize_name
  before_validation :normalize_post_ids
  before_validation :initialize_creator, :on => :create
  after_save :create_version
  after_save :update_posts
  attr_accessible :name, :description, :post_ids, :is_active, :post_id_array
  
  def self.name_to_id(name)
    if name =~ /^\d+$/
      name.to_i
    else
      select_value_sql("SELECT id FROM pools WHERE name = ?", name.downcase)
    end
  end
  
  def self.create_anonymous(creator, creator_ip_addr)
    Pool.new do |pool|
      pool.name = "TEMP:#{Time.now.to_f}.#{rand(1_000_000)}"
      pool.creator = creator
      pool.save
      pool.name = "anonymous:#{pool.id}"
      pool.save
    end
  end
  
  def initialize_creator
    self.creator_id = CurrentUser.id
  end
  
  def normalize_name
    self.name = name.downcase
  end
  
  def normalize_post_ids
    self.post_ids = post_ids.gsub(/\s\s+/, " ")
    self.post_ids = post_ids.gsub(/^\s+/, "")
    self.post_ids = post_ids.gsub(/\s+$/, "")
  end
  
  def revert_to!(version)
    self.post_ids = version.post_ids
    save
  end
  
  def update_posts
    post_id_array.each do |post_id|
      post = Post.find(post_id)
      post.add_pool(self)
    end
  end
  
  def add_post!(post)
    return if post_ids =~ /(?:\A| )#{post.id}(?:\Z| )/
    self.post_ids += " #{post.id}"
    self.post_ids = post_ids.strip
    clear_post_id_array
    save
  end
  
  def remove_post!(post)
    self.post_ids = post_ids.gsub(/(?:\A| )#{post.id}(?:\Z| )/, " ")
    self.post_ids = post_ids.strip
    clear_post_id_array
    save
  end
  
  def posts(options = {})
    offset = options[:offset] || 0
    limit = options[:limit] || Danbooru.config.posts_per_page
    ids = post_id_array[offset, limit]
    Post.where(["id IN (?)", ids]).order(Favorite.sql_order_clause(ids))
  end
  
  def post_id_array
    @post_id_array ||= post_ids.scan(/\d+/).map(&:to_i)
  end
  
  def post_id_array=(array)
    self.post_ids = array.join(" ")
    clear_post_id_array
  end
  
  def clear_post_id_array
    @post_id_array = nil
  end
  
  def neighbor_posts(post)
    @neighbor_posts ||= begin
      post_ids =~ /\A#{post.id} (\d+)|(\d+) #{post.id} (\d+)|(\d+) #{post.id}\Z/
      
      if $2 && $3
        {:previous => $2.to_i, :next => $3.to_i}
      elsif $1
        {:next => $1.to_i}
      elsif $4
        {:previous => $4.to_i}
      else
        {}
      end
    end
  end
  
  def create_version
    last_version = versions.last

    if last_version && CurrentUser.ip_addr == last_version.updater_ip_addr && CurrentUser.id == last_version.updater_id
      last_version.update_attribute(:post_ids, post_ids)
    else
      versions.create(:post_ids => post_ids)
    end
  end
  
  def reload(options = {})
    super
    @neighbor_posts = nil
    clear_post_id_array
  end
end
