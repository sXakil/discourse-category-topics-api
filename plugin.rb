# name: discourse-category-topics-api
# about: Adds a custom API endpoint to get topics in a category
# version: 1.0
# authors: sXakil
# url: https://github.com/sXakil/discourse-category-topics-api

enabled_site_setting :category_topics_api_enabled

after_initialize do
  module ::DiscourseCategoryTopicsApi
    class Engine < ::Rails::Engine
      engine_name "discourse_category_topics_api"
      isolate_namespace DiscourseCategoryTopicsApi
    end
  end

  require_dependency 'application_serializer'
  
  # frozen_string_literal: true

  class CustomCategoryTopicSerializer < ApplicationSerializer

    attributes :id,
               :slug,
               :title,
               :excerpt,
               :image_url,
               :views,
               :category_id,
               :like_count,
               :posts_count,
               :created_at,
               :visible
    
    has_one :user, serializer: BasicUserSerializer, embed: :objects
    has_many :tags, serializer: TagSerializer, embed: :objects

    def excerpt
      object.excerpt || ""
    end

    def category_id
      # If it's a shared draft, show the destination topic instead
      if object.includes_destination_category && object.shared_draft
        return object.shared_draft.category_id
      end

      object.category_id
    end
  end

  require_dependency 'application_controller'
  
  class ::CategoriesController
    requires_plugin "discourse-custom-api"

    before_action :check_rate_limit, only: [:topics]

    def check_rate_limit
      RateLimiter.new(nil, "category_topics_api", 60, 1.minute).performed!
    end

    def topics
      year = params[:year].to_i
      raise Discourse::NotFound if year < 2000 or year > Time.now.year

      category = Category.find_by(id: params[:id])
      raise Discourse::NotFound unless category
      
      guardian.ensure_can_see!(category)
      
      query = Topic
        .where(category_id: category.id)
        .where(created_at: DateTime.new(year).beginning_of_year..DateTime.new(year).end_of_year)
        .where(visible: true)
        .where(deleted_at: nil)
      
      order_by = params[:order] || 'created'
      case order_by
      when 'activity'
        query = query.order(bumped_at: :desc)
      when 'views'
        query = query.order(views: :desc)
      when 'posts'
        query = query.order(posts_count: :desc)
      when 'likes'
        query = query.order(like_count: :desc)
      else
        query = query.order(created_at: :desc)
      end
      
      if params[:status] == 'closed'
        query = query.where(closed: true)
      elsif params[:status] == 'open'
        query = query.where(closed: false)
      end
      
      if params[:pinned] == 'true'
        query = query.where('pinned_at IS NOT NULL')
      end

      topics = query.includes(:user, :tags)
      
      # Group topics by month
      grouped_topics = {}
      topics.each do |topic|
        month_key = topic.created_at.strftime('%Y-%m')
        year_from_topic = topic.created_at.year
        
        # Only include topics from the specified year
        if year_from_topic == year
          grouped_topics[month_key] ||= []
          grouped_topics[month_key] << topic
        end
      end

      total_count = grouped_topics.values.flatten.count

      # Serialize the grouped response
      serialized_topics = {}
      grouped_topics.each do |month_key, month_topics|
        serialized_topics[month_key] = serialize_data(month_topics, CustomCategoryTopicSerializer, scope: guardian)
      end

      stats = {}
      end_year = [year + 2, Time.now.year].min
      start_year = end_year - 4
      
      (start_year..end_year).each do |y|
        yearly_count = Topic
          .where(category_id: category.id)
          .where(created_at: DateTime.new(y).beginning_of_year..DateTime.new(y).end_of_year)
          .where(visible: true)
          .where(deleted_at: nil)
          .count
        stats[y] = yearly_count
      end

      render json: {
              topics: serialized_topics,
              stats: stats,
            }
    
    rescue Discourse::InvalidAccess
      render json: { error: "You do not have permission to view this" }, status: :forbidden
    rescue Discourse::NotFound
      render json: { error: "Category not found" }, status: :not_found
    end
  end

  Discourse::Application.routes.append do
    get "api/categories/:id/topics/:year" => "categories#topics", :defaults => { format: :json }
  end
end
