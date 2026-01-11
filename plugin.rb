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

    attributes :views,
               :like_count,
               :category_id,
               :image_url,
               :posts_count,
               :created_at,
               :visible,
               :excerpt
    
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

    requires_login except: [:topics]

    before_action :check_rate_limit, only: [:topics]

    def check_rate_limit
      RateLimiter.new(nil, "category_topics_api", 60, 1.minute).performed!
    end

    def topics
      category = Category.find_by(id: params[:id])
      
      raise Discourse::NotFound unless category
      
      guardian.ensure_can_see!(category)
      
      page = params[:page].to_i
      page_size = [(params[:page_size] || 30).to_i, 100].min
      
      query = Topic
        .where(category_id: category.id)
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

      total_count = query.count

      topics = query
        .offset(page * page_size)
        .limit(page_size)
        .includes(:user, :category, :tags)

      # Serialize the response
      render json: {
              topics: serialize_data(topics, CustomCategoryTopicSerializer, scope: guardian),
              meta: {
                total: total_count,
                page: page,
                page_size: page_size,
                has_more: (page + 1) * page_size < total_count,
              },
            }
    rescue Discourse::InvalidAccess
      render json: { error: "You do not have permission to view this" }, status: :forbidden
    rescue Discourse::NotFound
      render json: { error: "Category not found" }, status: :not_found
    end
  end

  Discourse::Application.routes.append do
    get "api/categories/:id/topics" => "categories#topics", :defaults => { format: :json }
  end
end
