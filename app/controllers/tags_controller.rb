class TagsController < ApplicationController
  before_action :set_tag, only: %i[edit update destroy]

  def index
    @tags = Current.family.tags.alphabetically
    @tag_ids_with_transactions = Tagging.where(tag_id: @tags.select(:id), taggable_type: "Transaction")
                                        .distinct
                                        .pluck(:tag_id)
                                        .to_set

    render layout: "settings"
  end

  def new
    @tag = Current.family.tags.new color: Tag::COLORS.sample
  end

  def create
    @tag = Current.family.tags.new(tag_params)

    if @tag.save
      redirect_to tags_path, notice: t(".created")
    else
      redirect_to tags_path, alert: t(".error", error: @tag.errors.full_messages.to_sentence)
    end
  end

  def edit
  end

  def update
    @tag.update!(tag_params)
    redirect_to tags_path, notice: t(".updated")
  end

  def destroy
    @tag.destroy!
    redirect_to tags_path, notice: t(".deleted")
  end

  def destroy_all
    Current.family.tags.destroy_all
    redirect_back_or_to tags_path, notice: t(".all_deleted")
  end

  private

    def set_tag
      @tag = Current.family.tags.find(params[:id])
    end

    def tag_params
      params.require(:tag).permit(:name, :color)
    end
end
