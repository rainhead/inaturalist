class ProviderAuthorizationsController < ApplicationController
  before_action :doorkeeper_authorize!,
    only: [ :destroy ],
    if: lambda { authenticate_with_oauth? }
  before_action :authenticate_user!, only: [ :destroy ],
    unless: lambda { authenticated_with_oauth? }
  protect_from_forgery prepend: true, except: :create, with: :exception, unless: lambda {
    authenticate_with_oauth? || authenticated_with_jwt?
  }

  # change the /auth/:provider/callback route to point to this if you want to examine the rack data returned by omniauth
  def auth_callback_test
    #render(:json=>request.env['omniauth.auth'].to_json)
  end

  def failure
    flash[:notice] = params[:message] || "Sorry, that login provider couldn't sign you in."
    redirect_back_or_default login_url
  end

  def destroy
    return render_404 unless request.delete?
    provider_authorization = current_user.has_provider_auth(params[:provider]) unless params[:provider].blank?
    provider_authorization ||= current_user.provider_authorizations.find_by_id( params[:id] )
    provider_authorization.destroy if provider_authorization
    respond_to do |format|
      format.html do
        flash[:notice] = if provider_authorization
          t(:you_unlinked_your_provider_account,
            provider: ProviderAuthorization::PROVIDER_NAMES[provider_authorization.provider_name]
          )
        else
          t(:failed_to_unlink_your_account)
        end
        redirect_to edit_person_url( current_user )
      end
      format.json do
        if provider_authorization
          head :no_content
        else
          render status: :unprocessable_entity, json: {
            error: t(:failed_to_unlink_account),
          }
        end
      end
    end
  end

  def create
    auth_info = request.env['omniauth.auth']
    
    case auth_info["provider"]
    when 'facebook'
      # omniauth bug sets fb nickname to 'profile.php?id=xxxxx' if no other nickname exists
      if auth_info["info"]["nickname"] && auth_info["info"]["nickname"].match("profile.php")
        auth_info["info"]["nickname"] = nil
      end
      # for some reason, omniauth doesn't populate image url
      # (maybe cause our version of omniauth was pre- fb graph api?)
      auth_info["info"]["image"] = "http://graph.facebook.com/#{auth_info["uid"]}/picture?type=large"
    when 'flickr'
      if auth_info["info"]["image"].blank?
        # construct the url for the user's flickr buddy icon
        nsid = auth_info['uid']
        flickr_info = flickr.people.getInfo(:user_id => nsid) # we make this api call to get the icon-farm and icon-server
        iconfarm = flickr_info['iconfarm']
        iconserver = flickr_info['iconserver']
        unless (iconfarm == 0 || iconserver == 0)
          auth_info["info"]["image"] = "http://farm#{iconfarm}.static.flickr.com/#{iconserver}/buddyicons/#{nsid}.jpg"
        end
      end
    when "apple"
      if auth_info["info"]["name"] && auth_info["info"]["name"]["firstName"]
        full_name = auth_info["info"]["name"]["firstName"]
        if auth_info["info"]["name"]["lastName"]
          full_name += " " + auth_info["info"]["name"]["lastName"]
        end
        auth_info["info"]["name"] = full_name
      end
    end
    
    
    if @provider_authorization = ProviderAuthorization.find_from_omniauth(auth_info)
      update_existing_provider_authorization(auth_info)
    else
      create_provider_authorization(auth_info)
    end
    
    if @provider_authorization && @provider_authorization.valid? && (scope = get_session_omniauth_scope)
      @provider_authorization.update(:scope => scope.to_s)
      session["omniauth_#{request.env['omniauth.strategy'].name}_scope"] = nil
    end

    # if this is a direct oauth bounce sign in, go directly to bounce_back
    if !session[:oauth_bounce].blank?
      redirect_to oauth_bounce_back_url
      return
    end
    
    if !session[:return_to].blank? && session[:return_to] != login_url
      @landing_path ||= session[:return_to]
    end
    
    # registering via an invite link in a flickr comment. see /flickr/invite
    if session[:invite_params]
      invite_params = session[:invite_params]
      session[:invite_params] = nil
      if @provider_authorization && @provider_authorization.valid? && @provider_authorization.created_at > 15.minutes.ago
        flash[:notice] = "Welcome to #{@site.name}! If these options look good, " +
          "click \"Save observation\" below and you'll be good to go!"
        invite_params.merge!(:welcome => true)
      end
      @landing_path = new_observation_url(invite_params)
    end
    redirect_to @landing_path || home_url
  end
  
  private
  def set_session_omniauth_scope
    return unless request.env['omniauth.strategy']
    session["omniauth_#{request.env['omniauth.strategy'].name}_scope"] = request.env['omniauth.strategy'].options[:scope]
  end
  
  def get_session_omniauth_scope
    session["omniauth_#{request.env['omniauth.strategy'].name}_scope"]
  end
  
  def create_provider_authorization(auth_info)
    email = auth_info.try(:[], 'info').try(:[], 'email')
    email ||= auth_info.try(:[], 'extra').try(:[], 'user_hash').try(:[], 'email')

    existing_user = current_user
    existing_user ||= User.where("lower(email) = ?", email.downcase).first unless email.blank?
    if auth_info['provider'] == 'flickr' && !auth_info['uid'].blank?
      existing_user ||= User.joins(:flickr_identity).where("flickr_identities.flickr_user_id = ?", auth_info['uid']).first
    end
    
    # if logged in or user with this email exists, link provider to existing inat user
    if existing_user
      sign_in(existing_user) unless logged_in?
      @provider_authorization = current_user.add_provider_auth(auth_info)
      if @provider_authorization && @provider_authorization.valid?
        flash[:notice] = t(:youve_successfully_linked_your_provider_account, provider: @provider_authorization.provider.to_s.capitalize)
      else
        msg = "There were problems linking your account"
        msg += ": #{@provider_authorization.errors.full_messages.to_sentence}" if @provider_authorization
        flash[:error] = msg
      end
      
    # create a new inat user and link provider to that user
    else
      sign_out(current_user) if current_user
      sign_in(User.create_from_omniauth(auth_info))
      @provider_authorization = current_user.provider_authorizations.last
      current_user.remember_me!
      current_user.update(:site => @site) if @site
      flash[:notice] = "Welcome!"
      if session[:invite_params].nil?
        flash[:allow_edit_after_auth] = true
        @landing_path = edit_after_auth_url
        return
      end
    end
    
    @landing_path ||= edit_user_path(current_user)
  end
  
  def update_existing_provider_authorization(auth_info)
    sign_in @provider_authorization.user
    @provider_authorization.user.remember_me
    @provider_authorization.update_with_auth_info(auth_info)
    @provider_authorization.touch
    set_request_locale
    if get_session_omniauth_scope.to_s == 'write' && @provider_authorization.scope != 'write'
      flash[:notice] = "You just authorized #{@site.site_name_short} to write to your account " +
        "on #{@provider_authorization.provider}. Thanks! Please try " +
        "what you were doing again.  We promise to be careful!"
    end
    @landing_path = session[:return_to] || home_path
  end

end
