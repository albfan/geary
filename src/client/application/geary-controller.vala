/*
 * Copyright 2016 Software Freedom Conservancy Inc.
 * Copyright 2016-2018 Michael Gratton <mike@vee.net>
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later). See the COPYING file in this distribution.
 */

// Required because Gcr's VAPI is behind-the-times
// TODO: When bindings available, use async variants of these calls
extern const string GCR_PURPOSE_SERVER_AUTH;
extern bool gcr_trust_add_pinned_certificate(Gcr.Certificate cert, string purpose, string peer,
    Cancellable? cancellable) throws Error;
extern bool gcr_trust_is_certificate_pinned(Gcr.Certificate cert, string purpose, string peer,
    Cancellable? cancellable) throws Error;
extern bool gcr_trust_remove_pinned_certificate(Gcr.Certificate cert, string purpose, string peer,
    Cancellable? cancellable) throws Error;

/**
 * Primary controller for a Geary application instance.
 */
public class GearyController : Geary.BaseObject {

    // Named actions.
    public const string ACTION_NEW_MESSAGE = "new-message";
    public const string ACTION_REPLY_TO_MESSAGE = "reply-to-message";
    public const string ACTION_REPLY_ALL_MESSAGE = "reply-all-message";
    public const string ACTION_FORWARD_MESSAGE = "forward-message";
    public const string ACTION_ARCHIVE_CONVERSATION = "archive-conv";
    public const string ACTION_TRASH_CONVERSATION = "trash-conv";
    public const string ACTION_DELETE_CONVERSATION = "delete-conv";
    public const string ACTION_EMPTY_SPAM = "empty-spam";
    public const string ACTION_EMPTY_TRASH = "empty-trash";
    public const string ACTION_UNDO = "undo";
    public const string ACTION_FIND_IN_CONVERSATION = "conv-find";
    public const string ACTION_ZOOM = "zoom";
    public const string ACTION_SHOW_MARK_MENU = "mark-message-menu";
    public const string ACTION_MARK_AS_READ = "mark-message-read";
    public const string ACTION_MARK_AS_UNREAD = "mark-message-unread";
    public const string ACTION_MARK_AS_STARRED = "mark-message-starred";
    public const string ACTION_MARK_AS_UNSTARRED = "mark-message-unstarred";
    public const string ACTION_MARK_AS_SPAM = "mark-message-spam";
    public const string ACTION_MARK_AS_NOT_SPAM = "mark-message-not-spam";
    public const string ACTION_COPY_MENU = "show-copy-menu";
    public const string ACTION_MOVE_MENU = "show-move-menu";
    public const string ACTION_SEARCH = "search-conv";
    public const string ACTION_CONVERSATION_LIST = "focus-conv-list";
    public const string ACTION_TOGGLE_SEARCH = "toggle-search";
    public const string ACTION_TOGGLE_FIND = "toggle-find";

    // Properties
    public const string PROP_CURRENT_CONVERSATION ="current-conversations";
    public const string PROP_SELECTED_CONVERSATIONS ="selected-conversations";

    public const int MIN_CONVERSATION_COUNT = 50;

    private const int SELECT_FOLDER_TIMEOUT_USEC = 100 * 1000;

    private const string PROP_ATTEMPT_OPEN_ACCOUNT = "attempt-open-account";


    private static string untitled_file_name;


    static construct {
        // Translators: File name used in save chooser when saving
        // attachments that do not otherwise have a name.
        GearyController.untitled_file_name = _("Untitled");
    }


    internal class AccountContext : Geary.BaseObject {

        public Geary.Account account { get; private set; }
        public Geary.Folder? inbox = null;
        public Geary.App.EmailStore store { get; private set; }
        public Cancellable cancellable { get; private set; default = new Cancellable(); }

        public AccountContext(Geary.Account account) {
            this.account = account;
            this.store = new Geary.App.EmailStore(account);
        }

    }


    public weak GearyApplication application { get; private set; } // circular ref

    public AccountManager? account_manager { get; private set; default = null; }

    public MainWindow? main_window { get; private set; default = null; }

    public Geary.App.ConversationMonitor? current_conversations { get; private set; default = null; }
    
    public AutostartManager? autostart_manager { get; private set; default = null; }
    
    public LoginDialog? login_dialog { get; private set; default = null; }

    public Application.AvatarStore? avatar_store {
        get; private set; default = null;
    }

    private Geary.Account? current_account = null;
    private Gee.Map<Geary.AccountInformation,AccountContext> accounts =
        new Gee.HashMap<Geary.AccountInformation,AccountContext>();

    private Geary.Folder? current_folder = null;
    private Cancellable cancellable_folder = new Cancellable();
    private Cancellable cancellable_search = new Cancellable();
    private Cancellable cancellable_open_account = new Cancellable();
    private Cancellable cancellable_context_dependent_buttons = new Cancellable();
    private ContactListStoreCache contact_list_store_cache = new ContactListStoreCache();
    private Gee.Set<Geary.App.Conversation> selected_conversations = new Gee.HashSet<Geary.App.Conversation>();
    private Geary.App.Conversation? last_deleted_conversation = null;
    private Gee.LinkedList<ComposerWidget> composer_widgets = new Gee.LinkedList<ComposerWidget>();
    private NewMessagesMonitor? new_messages_monitor = null;
    private NewMessagesIndicator? new_messages_indicator = null;
    private UnityLauncher? unity_launcher = null;
    private Libnotify? libnotify = null;
    private uint select_folder_timeout_id = 0;
    private int64 next_folder_select_allowed_usec = 0;
    private Geary.Nonblocking.Mutex select_folder_mutex = new Geary.Nonblocking.Mutex();
    private Geary.Folder? previous_non_search_folder = null;
    private UpgradeDialog upgrade_dialog;
    private Gee.List<string> pending_mailtos = new Gee.ArrayList<string>();
    private Geary.Nonblocking.Mutex untrusted_host_prompt_mutex = new Geary.Nonblocking.Mutex();
    private Gee.HashSet<Geary.Endpoint> validating_endpoints = new Gee.HashSet<Geary.Endpoint>();

    private uint operation_count = 0;
    private Geary.Revokable? revokable = null;

    // List of windows we're waiting to close before Geary closes.
    private Gee.List<ComposerWidget> waiting_to_close = new Gee.ArrayList<ComposerWidget>();

    private const ActionEntry[] win_action_entries = {
        {ACTION_NEW_MESSAGE,           on_new_message                  },
        {ACTION_CONVERSATION_LIST,     on_conversation_list            },
        {ACTION_FIND_IN_CONVERSATION,  on_find_in_conversation_action  },
        {ACTION_SEARCH,                on_search_activated             },
        {ACTION_EMPTY_SPAM,            on_empty_spam                   },
        {ACTION_EMPTY_TRASH,           on_empty_trash                  },
        {ACTION_UNDO,                  on_revoke                       },
        // Message actions
        {ACTION_REPLY_TO_MESSAGE,      on_reply_to_message_action   },
        {ACTION_REPLY_ALL_MESSAGE,     on_reply_all_message_action  },
        {ACTION_FORWARD_MESSAGE,       on_forward_message_action    },
        {ACTION_ARCHIVE_CONVERSATION,  on_archive_conversation      },
        {ACTION_TRASH_CONVERSATION,    on_trash_conversation        },
        {ACTION_DELETE_CONVERSATION,   on_delete_conversation       },
        {ACTION_COPY_MENU,             on_show_copy_menu            },
        {ACTION_MOVE_MENU,             on_show_move_menu            },
        // Message marking actions
        {ACTION_SHOW_MARK_MENU,     on_show_mark_menu           },
        {ACTION_MARK_AS_READ,       on_mark_as_read             },
        {ACTION_MARK_AS_UNREAD,     on_mark_as_unread           },
        {ACTION_MARK_AS_STARRED,    on_mark_as_starred          },
        {ACTION_MARK_AS_UNSTARRED,  on_mark_as_unstarred        },
        {ACTION_MARK_AS_SPAM,       on_mark_as_spam_toggle      },
        {ACTION_MARK_AS_NOT_SPAM,   on_mark_as_spam_toggle      },
        // Message viewer
        {ACTION_ZOOM,  on_zoom,  "s"  },
    };

    /**
     * Fired when the currently selected account has changed.
     */
    public signal void account_selected(Geary.Account? account);
    
    /**
     * Fired when the currently selected folder has changed.
     */
    public signal void folder_selected(Geary.Folder? folder);
    
    /**
     * Fired when the number of conversations changes.
     */
    public signal void conversation_count_changed(int count);
    
    /**
     * Fired when the search text is changed according to the controller.  This accounts
     * for a brief typmatic delay.
     */
    public signal void search_text_changed(string keywords);

    /**
     * Constructs a new instance of the controller.
     */
    public GearyController(GearyApplication application) {
        this.application = application;
    }

    ~GearyController() {
        assert(current_account == null);
    }

    /**
     * Starts the controller and brings up Geary.
     */
    public async void open_async(GLib.Cancellable? cancellable) {
        Geary.Engine engine = this.application.engine;

        // This initializes the IconFactory, important to do before
        // the actions are created (as they refer to some of Geary's
        // custom icons)
        IconFactory.instance.init();

        apply_app_menu_fix();

        // Listen for attempts to close the application.
        this.application.exiting.connect(on_application_exiting);

        // Create DB upgrade dialog.
        upgrade_dialog = new UpgradeDialog();
        upgrade_dialog.notify[UpgradeDialog.PROP_VISIBLE_NAME].connect(display_main_window_if_ready);

        // Initialise WebKit and WebViews
        ClientWebView.init_web_context(
            this.application.config,
            this.application.get_web_extensions_dir(),
            this.application.get_user_cache_directory().get_child("web-resources"),
            Args.log_debug
        );
        try {
            ClientWebView.load_scripts();
            ComposerWebView.load_resources();
            ConversationWebView.load_resources(
                this.application.get_user_config_directory()
            );
        } catch (Error err) {
            error("Error loading web resources: %s", err.message);
        }

        this.avatar_store = new Application.AvatarStore(
            this.application.config,
            this.application.get_user_cache_directory()
        );

        // Create the main window (must be done after creating actions.)
        main_window = new MainWindow(this.application);
        main_window.on_shift_key.connect(on_shift_key);
        main_window.notify["has-toplevel-focus"].connect(on_has_toplevel_focus);

        setup_actions();

        enable_message_buttons(false);

        engine.account_available.connect(on_account_available);
        engine.account_unavailable.connect(on_account_unavailable);
        engine.untrusted_host.connect(on_untrusted_host);

        // Connect to various UI signals.
        main_window.conversation_list_view.conversations_selected.connect(on_conversations_selected);
        main_window.conversation_list_view.conversation_activated.connect(on_conversation_activated);
        main_window.conversation_list_view.load_more.connect(on_load_more);
        main_window.conversation_list_view.mark_conversations.connect(on_mark_conversations);
        main_window.conversation_list_view.visible_conversations_changed.connect(on_visible_conversations_changed);
        main_window.folder_list.folder_selected.connect(on_folder_selected);
        main_window.folder_list.copy_conversation.connect(on_copy_conversation);
        main_window.folder_list.move_conversation.connect(on_move_conversation);
        main_window.main_toolbar.copy_folder_menu.folder_selected.connect(on_copy_conversation);
        main_window.main_toolbar.move_folder_menu.folder_selected.connect(on_move_conversation);
        main_window.search_bar.search_text_changed.connect((text) => { do_search(text); });
        main_window.conversation_viewer.conversation_added.connect(
            on_conversation_view_added
        );
        new_messages_monitor = new NewMessagesMonitor(should_notify_new_messages);
        main_window.folder_list.set_new_messages_monitor(new_messages_monitor);

        // New messages indicator (Ubuntuism)
        new_messages_indicator = NewMessagesIndicator.create(new_messages_monitor);
        new_messages_indicator.application_activated.connect(on_indicator_activated_application);
        new_messages_indicator.composer_activated.connect(on_indicator_activated_composer);
        new_messages_indicator.inbox_activated.connect(on_indicator_activated_inbox);

        unity_launcher = new UnityLauncher(new_messages_monitor);

        this.libnotify = new Libnotify(
            this.new_messages_monitor, this.avatar_store
        );
        this.libnotify.invoked.connect(on_libnotify_invoked);

        this.main_window.conversation_list_view.grab_focus();

        // instantiate here to ensure that Config is initialized and ready
        this.autostart_manager = new AutostartManager(this.application);

        // initialize revokable
        save_revokable(null, null);

        // Migrate configuration if necessary.
        try {
            Migrate.xdg_config_dir(this.application.get_user_data_directory(),
                this.application.get_user_config_directory());
        } catch (Error e) {
            error("Error migrating configuration directories: %s", e.message);
        }

        // Start Geary.
        this.account_manager = new AccountManager(
            this.application,
            this.application.get_user_config_directory(),
            this.application.get_user_data_directory()
        );
        this.account_manager.account_added.connect(
            on_account_added
        );
        this.account_manager.account_status_changed.connect(
            on_account_status_changed
        );

        try {
            yield this.account_manager.connect_libsecret(cancellable);
        } catch (GLib.Error err) {
            warning("Error opening libsecret: %s", err.message);
        }

        try {
            yield this.account_manager.connect_goa(cancellable);
        } catch (GLib.Error err) {
            warning("Error opening GOA: %s", err.message);
        }

        try {
            yield engine.open_async(
                this.application.get_resource_directory(), cancellable
            );
            yield this.account_manager.load_accounts(cancellable);
            if (engine.get_accounts().size == 0) {
                create_account();
            }
        } catch (Error e) {
            warning("Error opening Geary.Engine instance: %s", e.message);
        }
    }

    /**
     * At the moment, this is non-reversible, i.e. once closed a GearyController cannot be
     * re-opened.
     */
    public async void close_async() {
        Geary.Engine.instance.account_available.disconnect(on_account_available);
        Geary.Engine.instance.account_unavailable.disconnect(on_account_unavailable);
        Geary.Engine.instance.untrusted_host.disconnect(on_untrusted_host);

        // Release folder and conversations in the main window
        on_conversations_selected(new Gee.HashSet<Geary.App.Conversation>());
        on_folder_selected(null);

        // Disconnect from various UI signals.
        main_window.conversation_list_view.conversations_selected.disconnect(on_conversations_selected);
        main_window.conversation_list_view.conversation_activated.disconnect(on_conversation_activated);
        main_window.conversation_list_view.load_more.disconnect(on_load_more);
        main_window.conversation_list_view.mark_conversations.disconnect(on_mark_conversations);
        main_window.conversation_list_view.visible_conversations_changed.disconnect(on_visible_conversations_changed);
        main_window.folder_list.folder_selected.disconnect(on_folder_selected);
        main_window.folder_list.copy_conversation.disconnect(on_copy_conversation);
        main_window.folder_list.move_conversation.disconnect(on_move_conversation);
        main_window.main_toolbar.copy_folder_menu.folder_selected.disconnect(on_copy_conversation);
        main_window.main_toolbar.move_folder_menu.folder_selected.disconnect(on_move_conversation);
        main_window.conversation_viewer.conversation_added.disconnect(
            on_conversation_view_added
        );

        // hide window while shutting down, as this can take a few seconds under certain conditions
        main_window.hide();

        // Release monitoring early so held resources can be freed up
        this.libnotify = null;
        this.new_messages_indicator = null;
        this.unity_launcher = null;
        this.new_messages_monitor.clear_folders();
        this.new_messages_monitor = null;

        // drop the Revokable, which will commit it if necessary
        save_revokable(null, null);

        this.cancellable_open_account.cancel();

        // Close the ConversationMonitor
        if (current_conversations != null) {
            debug("Stopping conversation monitor for %s...",
                  this.current_conversations.base_folder.to_string());
            try {
                yield this.current_conversations.stop_monitoring_async(null);
            } catch (Error err) {
                debug(
                    "Error closing conversation monitor %s at shutdown: %s",
                    this.current_conversations.base_folder.to_string(),
                    err.message
                );
            }

            this.current_conversations = null;
        }

        // Create an array of known accounts so the loops below do not
        // explode if accounts are removed while iterating.
        AccountContext[] accounts = this.accounts.values.to_array();

        // Close all inboxes. Launch these in parallel first so we're
        // not wasting time waiting for each one to close. The account
        // will wait around for them to actually close.
        foreach (AccountContext context in accounts) {
            Geary.Folder? inbox = context.inbox;
            if (inbox != null) {
                debug("Closing inbox: %s...", inbox.to_string());
                inbox.close_async.begin(null, (obj, ret) => {
                        try {
                            inbox.close_async.end(ret);
                        } catch (Error err) {
                            debug(
                                "Error closing Inbox %s at shutdown: %s",
                                inbox.to_string(), err.message
                            );
                        }
                    });
                context.inbox = null;
            }
        }

        // Close all Accounts. Again, this is done in parallel to
        // minimise time taken to close, but here use a barrier to
        // wait for all to actually finish closing.
        Geary.Nonblocking.CountingSemaphore close_barrier =
            new Geary.Nonblocking.CountingSemaphore(null);
        foreach (AccountContext context in accounts) {
            close_barrier.acquire();
            this.close_account.begin(
                context.account.information,
                (obj, ret) => {
                    this.close_account.end(ret);
                    close_barrier.blind_notify();
                }
            );
        }
        try {
            yield close_barrier.wait_async();
        } catch (Error err) {
            debug("Error waiting at shutdown barrier: %s", err.message);
        }

        // Turn off the lights and lock the door behind you
        try {
            debug("Closing Engine...");
            yield Geary.Engine.instance.close_async(null);
            debug("Closed Engine");
        } catch (Error err) {
            message("Error closing Geary Engine instance: %s", err.message);
        }

        this.account_manager.account_added.disconnect(
            on_account_added
        );
        this.account_manager.account_status_changed.disconnect(
            on_account_status_changed
        );
        this.account_manager = null;

        this.application.remove_window(this.main_window);
        this.main_window.destroy();
        this.main_window = null;

        this.upgrade_dialog = null;

        if (login_dialog != null) {
            this.login_dialog.destroy();
            this.login_dialog = null;
        }

        this.current_account = null;
        this.current_folder = null;

        this.previous_non_search_folder = null;
        this.validating_endpoints.clear();

        this.selected_conversations = new Gee.HashSet<Geary.App.Conversation>();
        this.last_deleted_conversation = null;

        this.pending_mailtos.clear();
        this.composer_widgets.clear();
        this.waiting_to_close.clear();

        this.autostart_manager = null;

        this.avatar_store.close();
        this.avatar_store = null;


        debug("Closed GearyController");
    }

    /**
     * Opens a new, blank composer.
     */
    public void compose() {
        create_compose_widget(ComposerWidget.ComposeType.NEW_MESSAGE);
    }

    /**
     * Opens or queues a new composer addressed to a specific email address.
     */
    public void compose_mailto(string mailto) {
        if (current_account == null) {
            // Schedule the send for after we have an account open.
            pending_mailtos.add(mailto);
        } else {
            create_compose_widget(ComposerWidget.ComposeType.NEW_MESSAGE, null, null, mailto);
        }
    }

    /**
     * Closes an account and deletes it from disk.
     */
    public async void remove_account_async(Geary.AccountInformation info,
                                           Cancellable? cancellable = null) {
        try {
            yield close_account(info);
            this.application.engine.remove_account(info);
            yield this.account_manager.remove_account(info, cancellable);
        } catch (Error err) {
            report_problem(
                new Geary.ProblemReport(Geary.ProblemType.GENERIC_ERROR, err)
            );
        }
    }

    // Fix for clients having both:
    //   * disabled Gtk/ShellShowsAppMenu setting
    //   * no 'menu' setting in Gtk/DecorationLayout
    // See https://bugzilla.gnome.org/show_bug.cgi?id=770617
    private void apply_app_menu_fix() {
        Gtk.Settings? settings = Gtk.Settings.get_default();

        if (settings == null) {
            warning("Couldn't fetch Gtk default settings");
            return;
        }

        string decoration_layout = settings.gtk_decoration_layout ?? "";
        if (!decoration_layout.contains("menu")) {
            string prefix = "menu:";
            if (decoration_layout.contains(":")) {
                prefix = (decoration_layout.has_prefix(":")) ? "menu" : "menu,";
            }
            settings.gtk_decoration_layout = prefix + settings.gtk_decoration_layout;
        }
    }

    private void setup_actions() {
        this.main_window.add_action_entries(win_action_entries, this);

        add_window_accelerators(ACTION_MARK_AS_READ, { "<Ctrl>I", "<Shift>I" });
        add_window_accelerators(ACTION_MARK_AS_UNREAD, { "<Ctrl>U", "<Shift>U" });
        add_window_accelerators(ACTION_MARK_AS_STARRED, { "S" });
        add_window_accelerators(ACTION_MARK_AS_UNSTARRED, { "D" });
        add_window_accelerators(ACTION_MARK_AS_SPAM, { "<Ctrl>J", "exclam" }); // Exclamation mark (!)
        add_window_accelerators(ACTION_MARK_AS_NOT_SPAM, { "<Ctrl>J", "exclam" });
        add_window_accelerators(ACTION_COPY_MENU, { "L" });
        add_window_accelerators(ACTION_MOVE_MENU, { "M" });
        add_window_accelerators(ACTION_NEW_MESSAGE, { "<Ctrl>N", "N" });
        add_window_accelerators(ACTION_REPLY_TO_MESSAGE, { "<Ctrl>R", "R" });
        add_window_accelerators(ACTION_REPLY_ALL_MESSAGE, { "<Ctrl><Shift>R", "<Shift>R" });
        add_window_accelerators(ACTION_FORWARD_MESSAGE, { "<Ctrl>L", "F" });
        add_window_accelerators(ACTION_FIND_IN_CONVERSATION, { "<Ctrl>F", "slash" });
        add_window_accelerators(ACTION_ARCHIVE_CONVERSATION, { "A" });
        add_window_accelerators(ACTION_TRASH_CONVERSATION, { "Delete", "BackSpace" });
        add_window_accelerators(ACTION_DELETE_CONVERSATION, { "<Shift>Delete", "<Shift>BackSpace" });
        add_window_accelerators(ACTION_UNDO, { "<Ctrl>Z" });
        add_window_accelerators(ACTION_ZOOM+("('in')"), { "<Ctrl>equal", "equal" });
        add_window_accelerators(ACTION_ZOOM+("('out')"), { "<Ctrl>minus", "minus" });
        add_window_accelerators(ACTION_ZOOM+("('normal')"), { "<Ctrl>0", "0" });
        add_window_accelerators(ACTION_SEARCH, { "<Ctrl>S" });
        add_window_accelerators(ACTION_CONVERSATION_LIST, { "<Ctrl>B" });
    }

    private void add_window_accelerators(string action, string[] accelerators, Variant? param = null) {
        this.application.set_accels_for_action("win."+action, accelerators);
    }

    private void open_account(Geary.Account account) {
        account.report_problem.connect(on_report_problem);
        connect_account_async.begin(account, cancellable_open_account);

        ContactListStore list_store = this.contact_list_store_cache.create(account.get_contact_store());
        account.contacts_loaded.connect(list_store.set_sort_function);
    }

    private async void close_account(Geary.AccountInformation info) {
        AccountContext? context = this.accounts.get(info);
        if (context != null) {
            Geary.ContactStore contact_store = context.account.get_contact_store();
            ContactListStore list_store = this.contact_list_store_cache.get(contact_store);

            context.account.contacts_loaded.disconnect(list_store.set_sort_function);
            this.contact_list_store_cache.unset(contact_store);

            if (this.current_account == context.account) {
                this.current_account = null;

                previous_non_search_folder = null;
                main_window.search_bar.set_search_text(""); // Reset search.

                cancel_folder();
            }

            // Stop showing errors when closing the account - the user
            // doesn't care
            context.account.report_problem.disconnect(on_report_problem);

            yield disconnect_account_async(context);
        }
    }

    private void on_untrusted_host(Geary.AccountInformation account,
                                   Geary.ServiceInformation service,
                                   Geary.Endpoint.SecurityType security,
                                   TlsConnection cx) {
        this.prompt_untrusted_host_async.begin(account, service, security, cx);
    }

    private async void
        prompt_untrusted_host_async(Geary.AccountInformation account,
                                    Geary.ServiceInformation service,
                                    Geary.Endpoint.SecurityType security,
                                    TlsConnection cx) {
        // use a mutex to prevent multiple dialogs popping up at the same time
        int token = Geary.Nonblocking.Mutex.INVALID_TOKEN;
        try {
            token = yield untrusted_host_prompt_mutex.claim_async();
        } catch (Error err) {
            message("Unable to lock mutex to prompt user about invalid certificate: %s", err.message);
            return;
        }

        yield locked_prompt_untrusted_host_async(account, service, security, cx);

        try {
            untrusted_host_prompt_mutex.release(ref token);
        } catch (Error err) {
            message("Unable to release mutex after prompting user about invalid certificate: %s",
                err.message);
        }
    }

    private async void
        locked_prompt_untrusted_host_async(Geary.AccountInformation account,
                                           Geary.ServiceInformation service,
                                           Geary.Endpoint.SecurityType security,
                                           TlsConnection cx) {
        // possible while waiting on mutex that this endpoint became trusted or untrusted
        if (service.endpoint.trust_untrusted_host != Geary.Trillian.UNKNOWN)
            return;

        // get GCR parameters
        Gcr.Certificate cert;
        string peer;
        get_gcr_params(service.endpoint, out cert, out peer);

        // Geary allows for user to auto-revoke all questionable server certificates without
        // digging around in a keyring/pk manager
        if (Args.revoke_certs) {
            debug("Auto-revoking certificate for %s...", peer);
            
            try {
                gcr_trust_remove_pinned_certificate(cert, GCR_PURPOSE_SERVER_AUTH, peer, null);
            } catch (Error err) {
                message("Unable to auto-revoke server certificate for %s: %s", peer, err.message);
                
                // drop through, not absolutely valid to do this (might also mean certificate
                // was never pinned)
            }
        }
        
        // if pinned, the user has already made an exception for this server and its certificate,
        // so go ahead w/o asking
        try {
            if (gcr_trust_is_certificate_pinned(cert, GCR_PURPOSE_SERVER_AUTH, peer, null)) {
                debug("Certificate for %s is pinned, accepting connection...", peer);
                service.endpoint.trust_untrusted_host = Geary.Trillian.TRUE;
                return;
            }
        } catch (Error err) {
            message("Unable to check if server certificate for %s is pinned, assuming not: %s",
                peer, err.message);
        }

        // if these are in validation, there are complex GTK and workflow issues from simply
        // presenting the prompt now, so caller who connected will need to do it on their own dime
        if (!this.validating_endpoints.contains(service.endpoint))
            prompt_for_untrusted_host(main_window, account, service, false);
    }

    private void prompt_for_untrusted_host(Gtk.Window? parent,
                                           Geary.AccountInformation account,
                                           Geary.ServiceInformation service,
                                           bool is_validation) {
        CertificateWarningDialog dialog = new CertificateWarningDialog(
            parent, account, service, is_validation
        );
        Geary.Endpoint endpoint = service.endpoint;
        switch (dialog.run()) {
            case CertificateWarningDialog.Result.TRUST:
                endpoint.trust_untrusted_host = Geary.Trillian.TRUE;
            break;
            
            case CertificateWarningDialog.Result.ALWAYS_TRUST:
                endpoint.trust_untrusted_host = Geary.Trillian.TRUE;
                
                // get GCR parameters for pinning
                Gcr.Certificate cert;
                string peer;
                get_gcr_params(endpoint, out cert, out peer);
                
                // pinning the certificate creates an exception for the next time a connection
                // is attempted
                debug("Pinning certificate for %s...", peer);
                try {
                    gcr_trust_add_pinned_certificate(cert, GCR_PURPOSE_SERVER_AUTH, peer, null);
                } catch (Error err) {
                    ErrorDialog error_dialog = new ErrorDialog(main_window,
                        _("Unable to store server trust exception"), err.message);
                    error_dialog.run();
                }
            break;
            
            default:
                endpoint.trust_untrusted_host = Geary.Trillian.FALSE;

                // close the account; can't go any further w/o offline mode.
                this.close_account.begin(account);
            break;
        }
    }
    
    private void create_account() {
        Geary.AccountInformation? account_information = request_account_information(null);
        if (account_information != null)
            do_validate_until_successful_async.begin(account_information);
    }
    
    private async void do_validate_until_successful_async(Geary.AccountInformation account_information,
        Cancellable? cancellable = null) {
        Geary.AccountInformation? result = account_information;
        do {
            result = yield validate_or_retry_async(result, cancellable);
        } while (result != null);
        
        if (login_dialog != null)
            login_dialog.hide();
    }

    // Returns possibly modified validation results
    private Geary.Engine.ValidationResult validation_check_endpoint_for_tls_warnings(
        Geary.AccountInformation account, Geary.ServiceInformation service,
        Geary.Engine.ValidationResult validation_result, out bool prompted, out bool retry_required) {
        prompted = false;
        retry_required = false;

        // use LoginDialog for parent only if available and visible
        Gtk.Window? parent;
        if (login_dialog != null && login_dialog.visible)
            parent = login_dialog;
        else
            parent = main_window;

        Geary.Endpoint endpoint = service.endpoint;

        // If Endpoint had unresolved TLS issues, prompt user about them
        if (endpoint.tls_validation_warnings != 0 && endpoint.trust_untrusted_host != Geary.Trillian.TRUE) {
            prompt_for_untrusted_host(parent, account, service, true);
            prompted = true;
        }

        // If there are still TLS connection issues that caused the connection to fail (happens on the
        // first attempt), clear those errors and retry
        if (endpoint.tls_validation_warnings != 0 && endpoint.trust_untrusted_host == Geary.Trillian.TRUE) {
            Geary.Engine.ValidationResult flag = (service.protocol == Geary.Protocol.IMAP)
                ? Geary.Engine.ValidationResult.IMAP_CONNECTION_FAILED
                : Geary.Engine.ValidationResult.SMTP_CONNECTION_FAILED;

            if ((validation_result & flag) != 0) {
                validation_result &= ~flag;
                retry_required = true;
            }
        }
        
        return validation_result;
    }
    
    // Use after validating to see if TLS warnings were handled by the user and need to retry the
    // validation; this will also modify the validation results to better indicate issues to the user
    //
    // Returns possibly modified validation results
    public async Geary.Engine.ValidationResult validation_check_for_tls_warnings_async(
        Geary.AccountInformation account, Geary.Engine.ValidationResult validation_result,
        out bool retry_required) {
        retry_required = false;

        // Because TLS warnings need cycles to process, sleep and give 'em a chance to do their
        // thing ... note that the signal handler does *not* invoke the user prompt dialog when the
        // login dialog is in play, so this sleep does not need to worry about user input
        yield Geary.Scheduler.sleep_ms_async(100);

        // check each service for problems, prompting user each time for verification
        bool imap_prompted, imap_retry_required;
        validation_result = validation_check_endpoint_for_tls_warnings(
            account,
            account.imap,
            validation_result,
            out imap_prompted,
            out imap_retry_required
        );

        bool smtp_prompted, smtp_retry_required;
        validation_result = validation_check_endpoint_for_tls_warnings(
            account,
            account.smtp,
            validation_result,
            out smtp_prompted,
            out smtp_retry_required
        );

        // if prompted for user acceptance of bad certificates and they agreed to both, try again
        if (imap_prompted && smtp_prompted
            && account.imap.endpoint.is_trusted_or_never_connected
            && account.smtp.endpoint.is_trusted_or_never_connected) {
            retry_required = true;
        } else if (validation_result == Geary.Engine.ValidationResult.OK) {
            retry_required = true;
        } else {
            // if prompt requires retry or otherwise detected it, retry
            retry_required = imap_retry_required && smtp_retry_required;
        }
        
        return validation_result;
    }
    
    // Returns null if we are done validating, or the revised account information if we should retry.
    private async Geary.AccountInformation? validate_or_retry_async(Geary.AccountInformation account_information,
        Cancellable? cancellable = null) {
        Geary.Engine.ValidationResult result = yield validate_async(account_information,
            Geary.Engine.ValidationOption.CHECK_CONNECTIONS, cancellable);
        if (result == Geary.Engine.ValidationResult.OK)
            return null;
        
        // check Endpoints for trust (TLS) issues
        bool retry_required;
        result = yield validation_check_for_tls_warnings_async(account_information, result,
            out retry_required);
        
        // return for retry if required; check can also change validation results, in which case
        // revalidate entirely to have them written out
        if (retry_required)
            return account_information;
        
        debug("Validation failed. Prompting user for revised account information");
        Geary.AccountInformation? new_account_information =
            request_account_information(account_information, result);
        
        // If the user refused to enter account information. There is currently no way that we
        // could see this--we exit in request_account_information, and the only way that an
        // exit could be canceled is if there are unsaved composer windows open (which won't
        // happen before an account is created). However, best to include this check for the
        // future.
        if (new_account_information == null)
            return null;
        
        debug("User entered revised account information, retrying validation");
        return new_account_information;
    }
    
    // Attempts to validate and add an account.  Returns a result code indicating
    // success or one or more errors.
    public async Geary.Engine.ValidationResult validate_async(
        Geary.AccountInformation account_information, Geary.Engine.ValidationOption options,
        Cancellable? cancellable = null) {
        // add Endpoints to set of validating endpoints to prevent the prompt from appearing
        validating_endpoints.add(account_information.imap.endpoint);
        validating_endpoints.add(account_information.smtp.endpoint);

        Geary.Engine.ValidationResult result = Geary.Engine.ValidationResult.OK;
        try {
            result = yield Geary.Engine.instance.validate_account_information_async(account_information,
                options, cancellable);
        } catch (Error err) {
            debug("Error validating account: %s", err.message);
            this.application.exit(-1); // Fatal error

            return result;
        }

        validating_endpoints.remove(account_information.imap.endpoint);
        validating_endpoints.remove(account_information.smtp.endpoint);

        if (result == Geary.Engine.ValidationResult.OK) {
            Geary.AccountInformation real_account_information = account_information;
            if (account_information.is_copy) {
                // We have a temporary copy of the account.  Find the "real" acct info object and
                // copy the new data into it.
                real_account_information = get_real_account_information(account_information);
                real_account_information.copy_from(account_information);
            }

            try {
                if (real_account_information.settings_file == null) {
                    yield this.account_manager.create_account(
                        real_account_information, cancellable
                    );
                } else {
                    yield this.account_manager.save_account(
                        real_account_information, cancellable
                    );
                }
                debug("Successfully validated account information");
            } catch (GLib.Error err) {
                report_problem(
                    new Geary.ProblemReport(
                        Geary.ProblemType.GENERIC_ERROR, err
                    )
                );
            }
        }

        return result;
    }
    
    // Returns the "real" account info associated with a copy.  If it's not a copy, null is returned.
    public Geary.AccountInformation? get_real_account_information(
        Geary.AccountInformation account_information) {
        if (account_information.is_copy) {
            try {
                 return Geary.Engine.instance.get_accounts().get(account_information.id);
            } catch (Error e) {
                error("Account information is out of sync: %s", e.message);
            }
        }
        
        return null;
    }
    
    // Prompt the user for a service, real name, username, and password, and try to start Geary.
    private Geary.AccountInformation? request_account_information(Geary.AccountInformation? old_info,
        Geary.Engine.ValidationResult result = Geary.Engine.ValidationResult.OK) {
        Geary.AccountInformation? new_info = old_info;
        if (login_dialog == null) {
            // Create here so we know GTK is initialized.
            login_dialog = new LoginDialog(this.application);
        } else if (!login_dialog.get_visible()) {
            // If the dialog has been dismissed, exit here.
            this.application.exit();
            return null;
        }
        
        if (new_info != null)
            login_dialog.set_account_information(new_info, result);
        
        login_dialog.present();
        for (;;) {
            login_dialog.show_spinner(false);
            if (login_dialog.run() != Gtk.ResponseType.OK) {
                debug("User refused to enter account information. Exiting...");
                this.application.exit(1);
                return null;
            }
            
            login_dialog.show_spinner(true);
            new_info = login_dialog.get_account_information();
            
            if ((!new_info.imap.use_ssl && !new_info.imap.use_starttls)
                || (!new_info.smtp.use_ssl && !new_info.smtp.use_starttls)) {
                ConfirmationDialog security_dialog = new ConfirmationDialog(main_window,
                    _("Your settings are insecure"),
                    _("Your IMAP and/or SMTP settings do not specify SSL or TLS.  This means your username and password could be read by another person on the network.  Are you sure you want to do this?"),
                    _("Co_ntinue"));
                if (security_dialog.run() != Gtk.ResponseType.OK)
                    continue;
            }
            
            break;
        }
        
        return new_info;
    }

    private void report_problem(Geary.ProblemReport report) {
        debug("Problem reported: %s", report.to_string());

        if (!(report.error is IOError.CANCELLED)) {
            if (report.problem_type == Geary.ProblemType.SEND_EMAIL_SAVE_FAILED) {
                handle_outbox_failure(StatusBar.Message.OUTBOX_SAVE_SENT_MAIL_FAILED);
            } else {
                MainWindowInfoBar info_bar = new MainWindowInfoBar.for_problem(report);
                info_bar.retry.connect(on_retry_problem);
                this.main_window.show_infobar(info_bar);
            }
        }
    }

    private void on_retry_problem(MainWindowInfoBar info_bar) {
        Geary.ServiceProblemReport? service_report =
            info_bar.report as Geary.ServiceProblemReport;
        Error retry_err = null;
        if (service_report != null) {
            Geary.Account? account = null;
            try {
                account = this.application.engine.get_account_instance(
                    service_report.account
                );
            } catch (Error err) {
                debug("Error getting account for error retry: %s", err.message);
            }

            if (account != null && account.is_open()) {
                switch (service_report.service.protocol) {
                case Geary.Protocol.IMAP:
                    account.start_incoming_client.begin((obj, ret) => {
                            try {
                                account.start_incoming_client.end(ret);
                            } catch (Error err) {
                                retry_err = err;
                            }
                        });
                    break;

                case Geary.Protocol.SMTP:
                    account.start_outgoing_client.begin((obj, ret) => {
                            try {
                                account.start_outgoing_client.end(ret);
                            } catch (Error err) {
                                retry_err = err;
                            }
                        });
                    break;
                }

                if (retry_err != null) {
                    report_problem(
                        new Geary.ServiceProblemReport(
                            Geary.ProblemType.GENERIC_ERROR,
                            service_report.account,
                            service_report.service,
                            retry_err
                        )
                    );
                }
            }
        }
    }

    private void handle_outbox_failure(StatusBar.Message message) {
        bool activate_message = false;
        try {
            // Due to a timing hole where it's possible to delete a message
            // from the outbox after the SMTP queue has picked it up and is
            // in the process of sending it, we only want to display a message
            // telling the user there's a problem if there are any other
            // messages waiting to be sent on any account.
            foreach (Geary.AccountInformation info in Geary.Engine.instance.get_accounts().values) {
                Geary.Account account = Geary.Engine.instance.get_account_instance(info);
                if (account.is_open()) {
                    Geary.Folder? outbox = account.get_special_folder(Geary.SpecialFolderType.OUTBOX);
                    if (outbox != null && outbox.properties.email_total > 0) {
                        activate_message = true;
                        break;
                    }
                }
            }
        } catch (Error e) {
            debug("Error determining whether any outbox has messages: %s", e.message);
            activate_message = true;
        }
        
        if (activate_message) {
            if (!main_window.status_bar.is_message_active(message))
                main_window.status_bar.activate_message(message);
            switch (message) {
                case StatusBar.Message.OUTBOX_SEND_FAILURE:
                    libnotify.set_error_notification(_("Error sending email"),
                        _("Geary encountered an error sending an email.  If the problem persists, please manually delete the email from your Outbox folder."));
                break;
                
                case StatusBar.Message.OUTBOX_SAVE_SENT_MAIL_FAILED:
                    libnotify.set_error_notification(_("Error saving sent mail"),
                        _("Geary encountered an error saving a sent message to Sent Mail.  The message will stay in your Outbox folder until you delete it."));
                break;
                
                default:
                    assert_not_reached();
            }
        }
    }

    private void on_report_problem(Geary.Account account, Geary.ProblemReport problem) {
        report_problem(problem);
    }

    private void on_account_email_removed(Geary.Folder folder, Gee.Collection<Geary.EmailIdentifier> ids) {
        if (folder.special_folder_type == Geary.SpecialFolderType.OUTBOX) {
            main_window.status_bar.deactivate_message(StatusBar.Message.OUTBOX_SEND_FAILURE);
            main_window.status_bar.deactivate_message(StatusBar.Message.OUTBOX_SAVE_SENT_MAIL_FAILED);
            libnotify.clear_error_notification();
        }
    }
    
    private void on_sending_started() {
        main_window.status_bar.activate_message(StatusBar.Message.OUTBOX_SENDING);
    }
    
    private void on_sending_finished() {
        main_window.status_bar.deactivate_message(StatusBar.Message.OUTBOX_SENDING);
    }

    private async void connect_account_async(Geary.Account account, Cancellable? cancellable = null) {
        AccountContext context = new AccountContext(account);

        // XXX Need to set this early since
        // on_folders_available_unavailable expects it to be there
        this.accounts.set(account.information, context);

        account.email_sent.connect(on_sent);
        account.email_removed.connect(on_account_email_removed);
        account.folders_available_unavailable.connect(on_folders_available_unavailable);
        account.sending_monitor.start.connect(on_sending_started);
        account.sending_monitor.finish.connect(on_sending_finished);

        bool retry = false;
        do {
            try {
                account.set_data(PROP_ATTEMPT_OPEN_ACCOUNT, true);
                yield account.open_async(cancellable);
                retry = false;
            } catch (Error open_err) {
                debug("Unable to open account %s: %s", account.to_string(), open_err.message);

                if (open_err is Geary.EngineError.CORRUPT)
                    retry = yield account_database_error_async(account);
                else if (open_err is Geary.EngineError.PERMISSIONS)
                    yield account_database_perms_async(account);
                else if (open_err is Geary.EngineError.VERSION)
                    yield account_database_version_async(account);
                else
                    yield account_general_error_async(account);

                if (!retry) {
                    this.accounts.unset(account.information);
                    return;
                }
            }
        } while (retry);

        main_window.folder_list.set_user_folders_root_name(account, _("Labels"));
        display_main_window_if_ready();
    }
    
    // Returns true if the caller should try opening the account again
    private async bool account_database_error_async(Geary.Account account) {
        bool retry = true;
        
        // give the user two options: reset the Account local store, or exit Geary.  A third
        // could be done to leave the Account in an unopened state, but we don't currently
        // have provisions for that.
        QuestionDialog dialog = new QuestionDialog(main_window,
            _("Unable to open the database for %s").printf(account.information.id),
            _("There was an error opening the local mail database for this account. This is possibly due to corruption of the database file in this directory:\n\n%s\n\nGeary can rebuild the database and re-synchronize with the server or exit.\n\nRebuilding the database will destroy all local email and its attachments. <b>The mail on the your server will not be affected.</b>")
                .printf(account.information.data_dir.get_path()),
            _("_Rebuild"), _("E_xit"));
        dialog.use_secondary_markup(true);
        switch (dialog.run()) {
            case Gtk.ResponseType.OK:
                // don't use Cancellable because we don't want to interrupt this process
                try {
                    yield account.rebuild_async();
                } catch (Error err) {
                    ErrorDialog errdialog = new ErrorDialog(main_window,
                        _("Unable to rebuild database for “%s”").printf(account.information.id),
                        _("Error during rebuild:\n\n%s").printf(err.message));
                    errdialog.run();
                    
                    retry = false;
                }
            break;
            
            default:
                retry = false;
            break;
        }

        if (!retry)
            this.application.exit(1);

        return retry;
    }
    
    private async void account_database_perms_async(Geary.Account account) {
        // some other problem opening the account ... as with other flow path, can't run
        // Geary today with an account in unopened state, so have to exit
        ErrorDialog dialog = new ErrorDialog(main_window,
            _("Unable to open local mailbox for %s").printf(account.information.id),
            _("There was an error opening the local mail database for this account. This is possibly due to a file permissions problem.\n\nPlease check that you have read/write permissions for all files in this directory:\n\n%s")
                .printf(account.information.data_dir.get_path()));
        dialog.run();

        this.application.exit(1);
    }

    private async void account_database_version_async(Geary.Account account) {
        ErrorDialog dialog = new ErrorDialog(main_window,
            _("Unable to open local mailbox for %s").printf(account.information.id),
            _("The version number of the local mail database is formatted for a newer version of Geary. Unfortunately, the database cannot be “rolled back” to work with this version of Geary.\n\nPlease install the latest version of Geary and try again."));
        dialog.run();

        this.application.exit(1);
    }

    private async void account_general_error_async(Geary.Account account) {
        // some other problem opening the account ... as with other flow path, can't run
        // Geary today with an account in unopened state, so have to exit
        ErrorDialog dialog = new ErrorDialog(main_window,
            _("Unable to open local mailbox for %s").printf(account.information.id),
            _("There was an error opening the local account. This is probably due to connectivity issues.\n\nPlease check your network connection and restart Geary."));
        dialog.run();

        this.application.exit(1);
    }

    private async void disconnect_account_async(AccountContext context, Cancellable? cancellable = null) {
        debug("Disconnecting account: %s", context.account.information.id);

        Geary.Account account = context.account;

        // Guard against trying to disconnect the account twice
        this.accounts.unset(account.information);

        account.email_sent.disconnect(on_sent);
        account.email_removed.disconnect(on_account_email_removed);
        account.folders_available_unavailable.disconnect(on_folders_available_unavailable);
        account.sending_monitor.start.disconnect(on_sending_started);
        account.sending_monitor.finish.disconnect(on_sending_finished);

        main_window.folder_list.remove_account(account);

        context.cancellable.cancel();
        Geary.Folder? inbox = context.inbox;
        if (inbox != null) {
            try {
                yield inbox.close_async(cancellable);
            } catch (Error close_inbox_err) {
                debug("Unable to close monitored inbox: %s", close_inbox_err.message);
            }
            context.inbox = null;
        }

        try {
            yield account.close_async(cancellable);
        } catch (Error close_err) {
            debug("Unable to close account %s: %s", account.to_string(), close_err.message);
        }

        debug("Account closed: %s", account.to_string());
    }

    /**
     * Returns true if we've attempted to open all accounts at this point.
     */
    private bool did_attempt_open_all_accounts() {
        try {
            foreach (Geary.AccountInformation info in Geary.Engine.instance.get_accounts().values) {
                Geary.Account a = Geary.Engine.instance.get_account_instance(info);
                if (a.get_data<bool?>(PROP_ATTEMPT_OPEN_ACCOUNT) == null)
                    return false;
            }
        } catch(Error e) {
            error("Could not open accounts: %s", e.message);
        }
        
        return true;
    }
    
    /**
     * Displays the main window if we're ready.  Otherwise does nothing.
     */
    private void display_main_window_if_ready() {
        if (did_attempt_open_all_accounts() &&
            !upgrade_dialog.visible &&
            !cancellable_open_account.is_cancelled() &&
            !Args.hidden_startup)
            main_window.show();
    }
    
    /**
     * Returns the number of accounts that exist in Geary.  Note that not all accounts may be
     * open.  Zero is returned on an error.
     */
    public int get_num_accounts() {
        try {
            return Geary.Engine.instance.get_accounts().size;
        } catch (Error e) {
            debug("Error getting number of accounts: %s", e.message);
        }
        
        return 0; // on error
    }

    private bool is_inbox_descendant(Geary.Folder target) {
        bool is_descendent = false;

        Geary.Account account = target.account;
        Geary.Folder? inbox = null;
        try {
            inbox = account.get_special_folder(Geary.SpecialFolderType.INBOX);
        } catch (Error err) {
            debug("Failed to get inbox for account %s", account.information.id);
        }

        if (inbox != null) {
            is_descendent = inbox.path.is_descendant(target.path);
        }
        return is_descendent;
    }

    // Update widgets and such to match capabilities of the current folder ... sensitivity is handled
    // by other utility methods
    private void update_ui() {
        main_window.main_toolbar.selected_conversations = this.selected_conversations.size;
        main_window.main_toolbar.show_trash_button = current_folder_supports_trash() ||
                                                    !(current_folder is Geary.FolderSupport.Remove);
    }

    private void on_folder_selected(Geary.Folder? folder) {
        debug("Folder %s selected", folder != null ? folder.to_string() : "(null)");
        if (folder == null) {
            this.current_folder = null;
            main_window.conversation_list_view.set_model(null);
            main_window.main_toolbar.folder = null;
            folder_selected(null);
        } else if (folder != this.current_folder) {
            this.main_window.conversation_viewer.show_loading();
            get_window_action(ACTION_FIND_IN_CONVERSATION).set_enabled(false);
            enable_message_buttons(false);

            // To prevent the user from selecting folders too quickly,
            // we prevent additional selection changes to occur until
            // after a timeout has expired from the last one
            int64 now = get_monotonic_time();
            int64 diff = now - this.next_folder_select_allowed_usec;
            if (diff < SELECT_FOLDER_TIMEOUT_USEC) {
                // only start timeout if another timeout is not
                // running ... this means the user can click madly and
                // will see the last clicked-on folder 100ms after the
                // first one was clicked on
                if (this.select_folder_timeout_id == 0) {
                    this.select_folder_timeout_id = Timeout.add(
                        (uint) (diff / 1000),
                        () => {
                            this.select_folder_timeout_id = 0;
                            this.next_folder_select_allowed_usec = 0;
                            if (folder != this.current_folder) {
                                do_select_folder.begin(
                                    folder, on_select_folder_completed
                                );
                            }
                            return false;
                        });
                }
            } else {
                do_select_folder.begin(folder, on_select_folder_completed);
                this.next_folder_select_allowed_usec =
                    now + SELECT_FOLDER_TIMEOUT_USEC;
            }
        }
    }

    private async void do_select_folder(Geary.Folder folder) throws Error {
        debug("Switching to %s...", folder.to_string());
        
        closed_folder();
        
        // This function is not reentrant.  It should be, because it can be
        // called reentrant-ly if you select folders quickly enough.  This
        // mutex lock is a bandaid solution to make the function safe to
        // reenter.
        int mutex_token = yield select_folder_mutex.claim_async(cancellable_folder);

        // clear Revokable, as Undo is only available while a folder is selected
        save_revokable(null, null);
        
        // stop monitoring for conversations and close the folder
        if (current_conversations != null) {
            yield current_conversations.stop_monitoring_async(null);
            current_conversations = null;
        }
        
        // re-enable copy/move to the last selected folder
        if (current_folder != null) {
            main_window.main_toolbar.copy_folder_menu.enable_disable_folder(current_folder, true);
            main_window.main_toolbar.move_folder_menu.enable_disable_folder(current_folder, true);
        }

        this.current_folder = folder;

        if (this.current_account != folder.account) {
            this.current_account = folder.account;
            account_selected(this.current_account);

            // If we were waiting for an account to be selected before issuing mailtos, do that now.
            if (pending_mailtos.size > 0) {
                foreach(string mailto in pending_mailtos)
                    compose_mailto(mailto);
                
                pending_mailtos.clear();
            }

            main_window.main_toolbar.copy_folder_menu.clear();
            main_window.main_toolbar.move_folder_menu.clear();
            foreach(Geary.Folder f in current_folder.account.list_folders()) {
                main_window.main_toolbar.copy_folder_menu.add_folder(f);
                main_window.main_toolbar.move_folder_menu.add_folder(f);
            }
        }
        
        folder_selected(current_folder);
        
        if (!(current_folder is Geary.SearchFolder))
            previous_non_search_folder = current_folder;
        
        // disable copy/move to the new folder
        main_window.main_toolbar.copy_folder_menu.enable_disable_folder(current_folder, false);
        main_window.main_toolbar.move_folder_menu.enable_disable_folder(current_folder, false);
        
        update_ui();

        current_conversations = new Geary.App.ConversationMonitor(
            current_folder,
            Geary.Folder.OpenFlags.NO_DELAY,
            ConversationListStore.REQUIRED_FIELDS,
            MIN_CONVERSATION_COUNT
        );

        current_conversations.scan_completed.connect(on_scan_completed);
        current_conversations.scan_error.connect(on_scan_error);

        current_conversations.scan_completed.connect(on_conversation_count_changed);
        current_conversations.conversations_added.connect(on_conversation_count_changed);
        current_conversations.conversations_removed.connect(on_conversation_count_changed);

        clear_new_messages("do_select_folder", null);

        yield this.current_conversations.start_monitoring_async(
            this.cancellable_folder
        );

        select_folder_mutex.release(ref mutex_token);
        
        debug("Switched to %s", folder.to_string());
    }

    private void on_conversation_count_changed() {
        if (this.current_conversations != null) {
            ConversationListView list = this.main_window.conversation_list_view;
            ConversationViewer viewer = this.main_window.conversation_viewer;
            int count = this.current_conversations.size;
            if (count == 0) {
                // Let the user know if there's no available conversations
                if (this.current_folder is Geary.SearchFolder) {
                    viewer.show_empty_search();
                } else {
                    viewer.show_empty_folder();
                }
                enable_message_buttons(false);
            } else {
                // When not doing autoselect, we never get
                // conversations_selected firing from the convo list, so
                // we need to stop the loading spinner here
                if (!this.application.config.autoselect &&
                    list.get_selection().count_selected_rows() == 0) {
                    viewer.show_none_selected();
                    enable_message_buttons(false);
                }
            }
            conversation_count_changed(count);
        }
    }

    private void on_libnotify_invoked(Geary.Folder? folder, Geary.Email? email) {
        new_messages_monitor.clear_all_new_messages();
        
        if (folder == null || email == null || !can_switch_conversation_view())
            return;
        
        main_window.folder_list.select_folder(folder);
        Geary.App.Conversation? conversation = current_conversations.get_by_email_identifier(email.id);
        if (conversation != null)
            main_window.conversation_list_view.select_conversation(conversation);
    }

    private void on_indicator_activated_application(uint32 timestamp) {
        this.application.present();
    }

    private void on_indicator_activated_composer(uint32 timestamp) {
        on_indicator_activated_application(timestamp);
        on_new_message(null);
    }
    
    private void on_indicator_activated_inbox(Geary.Folder folder, uint32 timestamp) {
        on_indicator_activated_application(timestamp);
        main_window.folder_list.select_folder(folder);
    }
    
    private void on_load_more() {
        debug("on_load_more");
        current_conversations.min_window_count += MIN_CONVERSATION_COUNT;
    }
    
    private void on_select_folder_completed(Object? source, AsyncResult result) {
        try {
            do_select_folder.end(result);
        } catch (Error err) {
            debug("Unable to select folder: %s", err.message);
        }
    }

    private void on_conversations_selected(Gee.Set<Geary.App.Conversation> selected) {
        this.selected_conversations = selected;
        get_window_action(ACTION_FIND_IN_CONVERSATION).set_enabled(false);
        ConversationViewer viewer = this.main_window.conversation_viewer;
        if (this.current_folder != null && !viewer.is_composer_visible) {
            switch(selected.size) {
            case 0:
                enable_message_buttons(false);
                viewer.show_none_selected();
                break;

            case 1:
                // Cancel existing avatar loads before loading new
                // convo since that will start loading more avatars
                viewer.load_conversation.begin(
                    Geary.Collection.get_first(selected),
                    this.current_folder,
                    this.application.config,
                    this.avatar_store,
                    (obj, ret) => {
                        try {
                            viewer.load_conversation.end(ret);
                            enable_message_buttons(true);
                            get_window_action(ACTION_FIND_IN_CONVERSATION).set_enabled(true);
                        } catch (Error err) {
                            debug("Unable to load conversation: %s",
                                  err.message);
                        }
                    }
                );
                break;

            default:
                enable_multiple_message_buttons();
                viewer.show_multiple_selected();
                break;
            }
        }
    }

    private void on_conversation_activated(Geary.App.Conversation activated) {
        // Currently activating a conversation is only available for drafts folders.
        if (current_folder == null || current_folder.special_folder_type !=
            Geary.SpecialFolderType.DRAFTS)
            return;

        // TODO: Determine how to map between conversations and drafts correctly.
        Geary.Email draft = activated.get_latest_recv_email(
            Geary.App.Conversation.Location.IN_FOLDER
        );
        create_compose_widget(
            ComposerWidget.ComposeType.NEW_MESSAGE, draft, null, null, true
        );
    }

    private void on_special_folder_type_changed(Geary.Folder folder,
                                                Geary.SpecialFolderType old_type,
                                                Geary.SpecialFolderType new_type) {
        Geary.AccountInformation info = folder.account.information;

        // Update the main window
        this.main_window.folder_list.remove_folder(folder);
        this.main_window.folder_list.add_folder(folder);
        // Since removing the folder will also remove its children
        // from the folder list, we need to check for any and re-add
        // them. See isssue #11.
        try {
            foreach (Geary.Folder child in
                     folder.account.list_matching_folders(folder.path)) {
                main_window.folder_list.add_folder(child);
            }
        } catch (Error err) {
            // Oh well
        }

        // Update notifications
        this.new_messages_monitor.remove_folder(folder);
        if (folder.special_folder_type == Geary.SpecialFolderType.INBOX ||
            (folder.special_folder_type == Geary.SpecialFolderType.NONE &&
             is_inbox_descendant(folder))) {
            this.new_messages_monitor.add_folder(
                folder, this.accounts.get(info).cancellable
            );
        }

        this.account_manager.save_account.begin(
            info, null,
            (obj, res) => {
                try {
                    this.account_manager.save_account.end(res);
                } catch (GLib.Error err) {
                    report_problem(
                        new Geary.AccountProblemReport(
                            Geary.ProblemType.GENERIC_ERROR,
                            info,
                            err
                        )
                    );
                }
            }
        );
    }

    private void on_folders_available_unavailable(Geary.Account account,
                                                  Gee.List<Geary.Folder>? available,
                                                  Gee.List<Geary.Folder>? unavailable) {
        AccountContext context = this.accounts.get(account.information);

        if (available != null && available.size > 0) {
            foreach (Geary.Folder folder in available) {
                main_window.folder_list.add_folder(folder);
                if (folder.account == current_account) {
                    if (!main_window.main_toolbar.copy_folder_menu.has_folder(folder))
                        main_window.main_toolbar.copy_folder_menu.add_folder(folder);
                    if (!main_window.main_toolbar.move_folder_menu.has_folder(folder))
                        main_window.main_toolbar.move_folder_menu.add_folder(folder);
                }

                GLib.Cancellable cancellable = context.cancellable;

                switch (folder.special_folder_type) {
                case Geary.SpecialFolderType.INBOX:
                    // Special case handling of inboxes
                    if (context.inbox == null) {
                        context.inbox = folder;

                        // Select this inbox if there isn't an
                        // existing folder selected and it is the
                        // inbox for the first account
                        if (!main_window.folder_list.is_any_selected()) {
                            Geary.AccountInformation? first_account = null;
                            foreach (Geary.AccountInformation info in this.accounts.keys) {
                                if (first_account == null ||
                                    info.ordinal < first_account.ordinal) {
                                    first_account = info;
                                }
                            }
                            if (folder.account.information == first_account) {
                                // First we try to select the Inboxes branch inbox if
                                // it's there, falling back to the main folder list.
                                if (!main_window.folder_list.select_inbox(folder.account))
                                    main_window.folder_list.select_folder(folder);
                            }
                        }
                    }

                    folder.open_async.begin(Geary.Folder.OpenFlags.NO_DELAY, cancellable);

                    // Always notify for new messages in the Inbox
                    this.new_messages_monitor.add_folder(folder, cancellable);
                    break;

                case Geary.SpecialFolderType.NONE:
                    // Only notify for new messages in non-special
                    // descendants of the Inbox
                    if (is_inbox_descendant(folder)) {
                        this.new_messages_monitor.add_folder(folder, cancellable);
                    }
                    break;
                }

                folder.special_folder_type_changed.connect(on_special_folder_type_changed);
            }
        }

        if (unavailable != null) {
            for (int i = (unavailable.size - 1); i >= 0; i--) {
                Geary.Folder folder = unavailable[i];
                main_window.folder_list.remove_folder(folder);
                if (folder.account == current_account) {
                    if (main_window.main_toolbar.copy_folder_menu.has_folder(folder))
                        main_window.main_toolbar.copy_folder_menu.remove_folder(folder);
                    if (main_window.main_toolbar.move_folder_menu.has_folder(folder))
                        main_window.main_toolbar.move_folder_menu.remove_folder(folder);
                }

                switch (folder.special_folder_type) {
                case Geary.SpecialFolderType.INBOX:
                    context.inbox = null;
                    new_messages_monitor.remove_folder(folder);
                    break;

                case Geary.SpecialFolderType.NONE:
                    // Only notify for new messages in non-special
                    // descendants of the Inbox
                    if (is_inbox_descendant(folder)) {
                        this.new_messages_monitor.remove_folder(folder);
                    }
                    break;
                }

                folder.special_folder_type_changed.disconnect(on_special_folder_type_changed);
            }
        }
    }

    private void cancel_folder() {
        Cancellable old_cancellable = cancellable_folder;
        cancellable_folder = new Cancellable();
        
        old_cancellable.cancel();
    }
    
    // Like cancel_folder() but doesn't cancel outstanding operations, allowing them to complete
    // in the background
    private void closed_folder() {
        cancellable_folder = new Cancellable();
    }

    private void cancel_search() {
        Cancellable old_cancellable = this.cancellable_search;
        this.cancellable_search = new Cancellable();

        old_cancellable.cancel();
    }

    private void cancel_context_dependent_buttons() {
        Cancellable old_cancellable = cancellable_context_dependent_buttons;
        cancellable_context_dependent_buttons = new Cancellable();
        
        old_cancellable.cancel();
    }
    
    // We need to include the second parameter, or valac doesn't recognize the function as matching
    // GearyApplication.exiting's signature.
    private bool on_application_exiting(GearyApplication sender, bool panicked) {
        if (close_composition_windows())
            return true;
        
        return sender.cancel_exit();
    }

    private void on_shift_key(bool pressed) {
        if (main_window != null && main_window.main_toolbar != null
            && current_account != null && current_folder != null) {
            main_window.main_toolbar.show_trash_button =
                (!pressed && current_folder_supports_trash()) ||
                !(current_folder is Geary.FolderSupport.Remove);
        }
    }

    // this signal does not necessarily indicate that the application previously didn't have
    // focus and now it does
    private void on_has_toplevel_focus() {
        clear_new_messages("on_has_toplevel_focus", null);
    }

    // latest_sent_only uses Email's Date: field, which corresponds to
    // how they're sorted in the ConversationViewer, not whether they
    // are in the sent folder.
    private Gee.Collection<Geary.EmailIdentifier> get_conversation_email_ids(
        Gee.Collection<Geary.App.Conversation> conversations,
        bool latest_sent_only) {

        Gee.Collection<Geary.EmailIdentifier> ids =
            new Gee.ArrayList<Geary.EmailIdentifier>();

        // Blacklist the Outbox unless that's currently selected since
        // we don't want any operations to apply to messages there
        // normally.
        Gee.Collection<Geary.FolderPath>? blacklist = null;
        if (this.current_folder != null &&
            this.current_folder.special_folder_type != Geary.SpecialFolderType.OUTBOX) {
            Geary.Folder? outbox = null;
            try {
                outbox = this.current_account.get_special_folder(
                    Geary.SpecialFolderType.OUTBOX
                );

                blacklist = new Gee.ArrayList<Geary.FolderPath>();
                blacklist.add(outbox.path);
            } catch (GLib.Error err) {
                // Oh well
            }
        }

        foreach(Geary.App.Conversation conversation in conversations) {
            if (latest_sent_only) {
                Geary.Email? latest = conversation.get_latest_sent_email(
                    Geary.App.Conversation.Location.IN_FOLDER_OUT_OF_FOLDER,
                    blacklist
                );
                if (latest != null) {
                    ids.add(latest.id);
                }
            } else {
                Geary.traverse<Geary.Email>(
                    conversation.get_emails(
                        Geary.App.Conversation.Ordering.NONE,
                        Geary.App.Conversation.Location.ANYWHERE,
                        blacklist
                    )
                ).map<Geary.EmailIdentifier>(e => e.id)
                .add_all_to(ids);
            }
        }

        return ids;
    }

    private Gee.Collection<Geary.EmailIdentifier>
        get_selected_email_ids(bool latest_sent_only) {
        return get_conversation_email_ids(
            this.selected_conversations, latest_sent_only
        );
    }

    private void mark_email(Gee.Collection<Geary.EmailIdentifier> ids,
        Geary.EmailFlags? flags_to_add, Geary.EmailFlags? flags_to_remove) {
        if (ids.size > 0) {
            get_store_for_folder(current_folder).mark_email_async.begin(
                ids, flags_to_add, flags_to_remove, cancellable_folder);
        }
    }
    
    private void on_show_mark_menu() {
        bool unread_selected = false;
        bool read_selected = false;
        bool starred_selected = false;
        bool unstarred_selected = false;
        foreach (Geary.App.Conversation conversation in selected_conversations) {
            if (conversation.is_unread())
                unread_selected = true;
            
            // Only check the messages that "Mark as Unread" would mark, so we
            // don't add the menu option and have it not do anything.
            //
            // Sort by Date: field to correspond with ConversationViewer ordering
            Geary.Email? latest = conversation.get_latest_sent_email(
                Geary.App.Conversation.Location.IN_FOLDER_OUT_OF_FOLDER);
            if (latest != null && latest.email_flags != null
                && !latest.email_flags.contains(Geary.EmailFlags.UNREAD))
                read_selected = true;

            if (conversation.is_flagged()) {
                starred_selected = true;
            } else {
                unstarred_selected = true;
            }
        }
        get_window_action(ACTION_MARK_AS_READ).set_enabled(unread_selected);
        get_window_action(ACTION_MARK_AS_UNREAD).set_enabled(read_selected);
        get_window_action(ACTION_MARK_AS_STARRED).set_enabled(unstarred_selected);
        get_window_action(ACTION_MARK_AS_UNSTARRED).set_enabled(starred_selected);

        bool in_spam_folder = current_folder.special_folder_type == Geary.SpecialFolderType.SPAM;
        get_window_action(ACTION_MARK_AS_NOT_SPAM).set_enabled(in_spam_folder);
        // If we're in Drafts/Outbox, we also shouldn't set a message as SPAM.
        get_window_action(ACTION_MARK_AS_SPAM).set_enabled(!in_spam_folder &&
            current_folder.special_folder_type != Geary.SpecialFolderType.DRAFTS &&
            current_folder.special_folder_type != Geary.SpecialFolderType.OUTBOX);
    }

    private void on_visible_conversations_changed(Gee.Set<Geary.App.Conversation> visible) {
        clear_new_messages("on_visible_conversations_changed", visible);
    }
    
    private bool should_notify_new_messages(Geary.Folder folder) {
        // A monitored folder must be selected to squelch notifications;
        // if conversation list is at top of display, don't display
        // and don't display if main window has top-level focus
        return folder != current_folder
            || main_window.conversation_list_view.vadjustment.value != 0.0
            || !main_window.has_toplevel_focus;
    }
    
    // Clears messages if conditions are true: anything in should_notify_new_messages() is
    // false and the supplied visible messages are visible in the conversation list view
    private void clear_new_messages(string caller, Gee.Set<Geary.App.Conversation>? supplied) {
        if (current_folder == null || !new_messages_monitor.get_folders().contains(current_folder)
            || should_notify_new_messages(current_folder))
            return;
        
        Gee.Set<Geary.App.Conversation> visible =
            supplied ?? main_window.conversation_list_view.get_visible_conversations();
        
        foreach (Geary.App.Conversation conversation in visible) {
            if (new_messages_monitor.are_any_new_messages(current_folder, conversation.get_email_ids())) {
                debug("Clearing new messages: %s", caller);
                new_messages_monitor.clear_new_messages(current_folder);
                
                break;
            }
        }
    }

    private void on_mark_conversations(Gee.Collection<Geary.App.Conversation> conversations,
        Geary.EmailFlags? flags_to_add, Geary.EmailFlags? flags_to_remove,
        bool latest_only = false) {
        mark_email(get_conversation_email_ids(conversations, latest_only),
            flags_to_add, flags_to_remove);
    }

    private void on_conversation_viewer_mark_emails(Gee.Collection<Geary.EmailIdentifier> emails,
        Geary.EmailFlags? flags_to_add, Geary.EmailFlags? flags_to_remove) {
        mark_email(emails, flags_to_add, flags_to_remove);
    }

    private void on_mark_as_read(SimpleAction action) {
        Geary.EmailFlags flags = new Geary.EmailFlags();
        flags.add(Geary.EmailFlags.UNREAD);

        Gee.Collection<Geary.EmailIdentifier> ids = get_selected_email_ids(false);
        mark_email(ids, null, flags);

        ConversationListBox? list =
            main_window.conversation_viewer.current_list;
        if (list != null) {
            foreach (Geary.EmailIdentifier id in ids)
                list.mark_manual_read(id);
        }
    }

    private void on_mark_as_unread(SimpleAction action) {
        Geary.EmailFlags flags = new Geary.EmailFlags();
        flags.add(Geary.EmailFlags.UNREAD);

        Gee.Collection<Geary.EmailIdentifier> ids = get_selected_email_ids(true);
        mark_email(ids, flags, null);

        ConversationListBox? list =
            main_window.conversation_viewer.current_list;
        if (list != null) {
            foreach (Geary.EmailIdentifier id in ids)
                list.mark_manual_unread(id);
        }
    }

    private void on_mark_as_starred(SimpleAction action) {
        Geary.EmailFlags flags = new Geary.EmailFlags();
        flags.add(Geary.EmailFlags.FLAGGED);
        mark_email(get_selected_email_ids(true), flags, null);
    }

    private void on_mark_as_unstarred(SimpleAction action) {
        Geary.EmailFlags flags = new Geary.EmailFlags();
        flags.add(Geary.EmailFlags.FLAGGED);
        mark_email(get_selected_email_ids(false), null, flags);
    }

    private void on_show_move_menu(SimpleAction? action) {
        this.main_window.main_toolbar.copy_message_button.clicked();
    }

    private void on_show_copy_menu(SimpleAction? action) {
        this.main_window.main_toolbar.move_message_button.clicked();
    }

    private async void mark_as_spam_toggle_async(Cancellable? cancellable) {
        Geary.Folder? destination_folder = null;
        if (current_folder.special_folder_type != Geary.SpecialFolderType.SPAM) {
            // Move to spam folder.
            try {
                destination_folder = yield current_account.get_required_special_folder_async(
                    Geary.SpecialFolderType.SPAM, cancellable);
            } catch (Error e) {
                debug("Error getting spam folder: %s", e.message);
            }
        } else {
            // Move out of spam folder, back to inbox.
            try {
                destination_folder = current_account.get_special_folder(Geary.SpecialFolderType.INBOX);
            } catch (Error e) {
                debug("Error getting inbox folder: %s", e.message);
            }
        }

        if (destination_folder != null)
            on_move_conversation(destination_folder);
    }

    private void on_mark_as_spam_toggle(SimpleAction action) {
        mark_as_spam_toggle_async.begin(null);
    }

    private void copy_email(Gee.Collection<Geary.EmailIdentifier> ids,
        Geary.FolderPath destination) {
        if (ids.size > 0) {
            get_store_for_folder(current_folder).copy_email_async.begin(
                ids, destination, cancellable_folder
            );
        }
    }

    private void on_copy_conversation(Geary.Folder destination) {
        copy_email(get_selected_email_ids(false), destination.path);
    }
    
    private void on_move_conversation(Geary.Folder destination) {
        // Nothing to do if nothing selected.
        if (selected_conversations == null || selected_conversations.size == 0)
            return;
        
        Gee.Collection<Geary.EmailIdentifier> ids = get_selected_email_ids(false);
        if (ids.size == 0)
            return;

        selection_operation_started();

        Geary.FolderSupport.Move? supports_move = current_folder as Geary.FolderSupport.Move;
        if (supports_move != null)
            move_conversation_async.begin(
                supports_move, ids, destination.path, cancellable_folder,
                (obj, ret) => {
                    move_conversation_async.end(ret);
                    selection_operation_finished();
                });
    }

    private async void move_conversation_async(Geary.FolderSupport.Move source_folder,
                                               Gee.Collection<Geary.EmailIdentifier> ids,
                                               Geary.FolderPath destination,
                                               Cancellable? cancellable) {
        try {
            save_revokable(yield source_folder.move_email_async(ids, destination, cancellable),
                _("Undo move (Ctrl+Z)"));
        } catch (Error err) {
            debug("%s: Unable to move %d emails: %s", source_folder.to_string(), ids.size,
                err.message);
        }
    }

    private void on_attachments_activated(Gee.Collection<Geary.Attachment> attachments) {
        if (this.application.config.ask_open_attachment) {
            QuestionDialog ask_to_open = new QuestionDialog.with_checkbox(main_window,
                _("Are you sure you want to open these attachments?"),
                _("Attachments may cause damage to your system if opened.  Only open files from trusted sources."),
                Stock._OPEN_BUTTON, Stock._CANCEL, _("Don’t _ask me again"), false);
            if (ask_to_open.run() != Gtk.ResponseType.OK) {
                return;
            }
            // only save checkbox state if OK was selected
            this.application.config.ask_open_attachment = !ask_to_open.is_checked;
        }

        foreach (Geary.Attachment attachment in attachments) {
            string uri = attachment.file.get_uri();
            try {
                this.application.show_uri(uri);
            } catch (Error err) {
                message("Unable to open attachment \"%s\": %s", uri, err.message);
            }
        }
    }

    private async void save_attachment_to_file(Geary.Attachment attachment,
                                               string? alt_text,
                                               GLib.Cancellable cancellable) {
        string alt_display_name = Geary.String.is_empty_or_whitespace(alt_text)
            ? GearyController.untitled_file_name : alt_text;
        string display_name = yield attachment.get_safe_file_name(
            alt_display_name
        );

        Geary.Memory.FileBuffer? content = null;
        try {
            content = new Geary.Memory.FileBuffer(attachment.file, true);
        } catch (GLib.Error err) {
            warning(
                "Error opening attachment file \"%s\": %s",
                attachment.file.get_uri(), err.message
            );
            report_problem(
                new Geary.ProblemReport(Geary.ProblemType.GENERIC_ERROR, err)
            );
        }

        yield this.prompt_save_buffer(display_name, content, cancellable);
    }

    private async void
        save_attachments_to_file(Gee.Collection<Geary.Attachment> attachments,
                                 GLib.Cancellable? cancellable) {
        Gtk.FileChooserNative dialog = new_save_chooser(Gtk.FileChooserAction.SELECT_FOLDER);

        bool accepted = (dialog.run() == Gtk.ResponseType.ACCEPT);
        string? filename = dialog.get_filename();
        dialog.destroy();
        if (!accepted || Geary.String.is_empty(filename))
            return;

        File dest_dir = File.new_for_path(filename);
        foreach (Geary.Attachment attachment in attachments) {
            Geary.Memory.FileBuffer? content = null;
            GLib.File? dest = null;
            try {
                content = new Geary.Memory.FileBuffer(attachment.file, true);
                dest = dest_dir.get_child_for_display_name(
                    yield attachment.get_safe_file_name(
                        GearyController.untitled_file_name
                    )
                );
            } catch (GLib.Error err) {
                warning(
                    "Error opening attachment files \"%s\": %s",
                    attachment.file.get_uri(), err.message
                );
                report_problem(
                    new Geary.ProblemReport(
                        Geary.ProblemType.GENERIC_ERROR, err
                    )
                );
            }

            if (content != null &&
                dest != null &&
                yield check_overwrite(dest, cancellable)) {
                yield write_buffer_to_file(content, dest, cancellable);
            }
        }
    }

    private async void prompt_save_buffer(string display_name,
                                          Geary.Memory.Buffer buffer,
                                          GLib.Cancellable? cancellable) {
        Gtk.FileChooserNative dialog = new_save_chooser(
            Gtk.FileChooserAction.SAVE
        );
        dialog.set_current_name(display_name);

        string? accepted_path = null;
        if (dialog.run() == Gtk.ResponseType.ACCEPT) {
            accepted_path = dialog.get_filename();
        }
        dialog.destroy();

        if (!Geary.String.is_empty_or_whitespace(accepted_path)) {
            GLib.File dest_file = File.new_for_path(accepted_path);
            if (yield check_overwrite(dest_file, cancellable)) {
                yield write_buffer_to_file(buffer, dest_file, cancellable);
            }
        }
    }

    private async bool check_overwrite(GLib.File to_overwrite,
                                       GLib.Cancellable? cancellable) {
        bool overwrite = true;
        try {
            GLib.FileInfo file_info = yield to_overwrite.query_info_async(
                GLib.FileAttribute.STANDARD_DISPLAY_NAME,
                GLib.FileQueryInfoFlags.NONE,
                GLib.Priority.DEFAULT,
                cancellable
            );
            GLib.FileInfo parent_info = yield to_overwrite.get_parent()
                .query_info_async(
                    GLib.FileAttribute.STANDARD_DISPLAY_NAME,
                    GLib.FileQueryInfoFlags.NONE,
                    GLib.Priority.DEFAULT,
                    cancellable
                );

            // Translators: Dialog primary label when prompting to
            // overwrite a file. The string substitution is the file'sx
            // name.
            string primary = _(
                "A file named “%s” already exists.  Do you want to replace it?"
            ).printf(file_info.get_display_name());

            // Translators: Dialog secondary label when prompting to
            // overwrite a file. The string substitution is the parent
            // folder's name.
            string secondary = _(
                "The file already exists in “%s”.  Replacing it will overwrite its contents."
            ).printf(parent_info.get_display_name());

            ConfirmationDialog dialog = new ConfirmationDialog(
                main_window, primary, secondary, _("_Replace"), "destructive-action"
            );
            overwrite = (dialog.run() == Gtk.ResponseType.OK);
        } catch (GLib.Error err) {
            // Oh well
        }
        return overwrite;
    }

    private async void write_buffer_to_file(Geary.Memory.Buffer buffer,
                                            File dest,
                                            GLib.Cancellable? cancellable) {
        try {
            FileOutputStream outs = dest.replace(
                null, false, FileCreateFlags.REPLACE_DESTINATION, cancellable
            );
            yield outs.splice_async(
                buffer.get_input_stream(),
                OutputStreamSpliceFlags.CLOSE_SOURCE | OutputStreamSpliceFlags.CLOSE_TARGET,
                Priority.DEFAULT,
                cancellable
            );
        } catch (GLib.IOError.CANCELLED err) {
            try {
                yield dest.delete_async(GLib.Priority.HIGH, null);
            } catch (GLib.Error err) {
                // Oh well
            }
        } catch (GLib.Error err) {
            warning(
                "Error writing buffer \"%s\": %s",
                dest.get_uri(), err.message
            );
            report_problem(
                new Geary.ProblemReport(Geary.ProblemType.GENERIC_ERROR, err)
            );
        }
    }

    private inline Gtk.FileChooserNative new_save_chooser(Gtk.FileChooserAction action) {
        Gtk.FileChooserNative dialog = new Gtk.FileChooserNative(
            null,
            this.main_window,
            action,
            Stock._SAVE,
            Stock._CANCEL
        );
        dialog.set_local_only(false);
        return dialog;
    }

    // Opens a link in an external browser.
    private bool open_uri(string _link) {
        string link = _link;

        // Support web URLs that ommit the protocol.
        if (!link.contains(":"))
            link = "http://" + link;

        bool success = true;
        try {
            this.application.show_uri(link);
        } catch (Error err) {
            success = false;
            debug("Unable to open URL: \"%s\" %s", link, err.message);
        }

        return success;
    }

    internal bool close_composition_windows(bool main_window_only = false) {
        Gee.List<ComposerWidget> composers_to_destroy = new Gee.ArrayList<ComposerWidget>();
        bool quit_cancelled = false;

        // If there's composer windows open, give the user a chance to
        // save or cancel.
        foreach(ComposerWidget cw in composer_widgets) {
            if (!main_window_only ||
                cw.state != ComposerWidget.ComposerState.DETACHED) {
                // Check if we should close the window immediately, or
                // if we need to wait.
                ComposerWidget.CloseStatus status = cw.should_close();
                if (status == ComposerWidget.CloseStatus.PENDING_CLOSE) {
                    // Window is currently busy saving.
                    waiting_to_close.add(cw);
                } else if (status == ComposerWidget.CloseStatus.CANCEL_CLOSE) {
                    // User cancelled operation.
                    quit_cancelled = true;
                    break;
                } else if (status == ComposerWidget.CloseStatus.DO_CLOSE) {
                    // Hide any existing composer windows for the
                    // moment; actually deleting the windows will
                    // result in their removal from composer_windows,
                    // which could crash this loop.
                    composers_to_destroy.add(cw);
                    ((ComposerContainer) cw.parent).vanish();
                }
            }
        }

        // Safely destroy windows.
        foreach(ComposerWidget cw in composers_to_destroy)
            ((ComposerContainer) cw.parent).close_container();
        
        // If we cancelled the quit we can bail here.
        if (quit_cancelled) {
            waiting_to_close.clear();
            
            return false;
        }
        
        // If there's still windows saving, we can't exit just yet.  Hide the main window and wait.
        if (waiting_to_close.size > 0) {
            main_window.hide();
            
            return false;
        }
        
        // If we deleted all composer windows without the user cancelling, we can exit.
        return true;
    }

    // View contains the email from whose menu this reply or forward
    // was triggered.  If null, this was triggered from the headerbar
    // or shortcut.
    private void create_reply_forward_widget(ComposerWidget.ComposeType compose_type,
                                             owned ConversationEmail? email_view) {
        if (email_view == null) {
            ConversationListBox? list_view =
                main_window.conversation_viewer.current_list;
            if (list_view != null) {
                email_view = list_view.get_reply_target();
            }
        }

        if (email_view != null) {
            email_view.get_selection_for_quoting.begin((obj, res) => {
                    string? quote = email_view.get_selection_for_quoting.end(res);
                    create_compose_widget(compose_type, email_view.email, quote);
                });
        } else {
            create_compose_widget(compose_type, email_view.email, null);
        }
    }

    private void create_compose_widget(ComposerWidget.ComposeType compose_type,
        Geary.Email? referred = null, string? quote = null, string? mailto = null,
        bool is_draft = false) {
        create_compose_widget_async.begin(compose_type, referred, quote, mailto, is_draft);
    }

    /**
     * Creates a composer widget. Depending on the arguments, this can be inline in the
     * conversation or as a new window.
     * @param compose_type - Whether it's a new message, a reply, a forwarded mail, ...
     * @param referred - The mail of which we should copy the from/to/... addresses
     * @param quote - The quote after the mail body
     * @param mailto - A "mailto:"-link
     * @param is_draft - Whether we're starting from a draft (true) or a new mail (false)
     */
    private async void create_compose_widget_async(ComposerWidget.ComposeType compose_type,
        Geary.Email? referred = null, string? quote = null, string? mailto = null,
        bool is_draft = false) {
        if (current_account == null)
            return;
        
        bool inline;
        if (!should_create_new_composer(compose_type, referred, quote, is_draft, out inline))
            return;

        ComposerWidget widget;
        if (mailto != null) {
            widget = new ComposerWidget.from_mailto(current_account, contact_list_store_cache,
                mailto, application.config);
        } else {
            widget = new ComposerWidget(current_account, contact_list_store_cache, compose_type, application.config);
        }
        widget.destroy.connect(on_composer_widget_destroy);
        widget.link_activated.connect((uri) => { open_uri(uri); });

        // We want to keep track of the open composer windows, so we can allow the user to cancel
        // an exit without losing their data.
        composer_widgets.add(widget);
        debug(@"Creating composer of type $(widget.compose_type); $(composer_widgets.size) composers total");

        if (inline) {
            if (widget.state == ComposerWidget.ComposerState.PANED) {
                main_window.conversation_viewer.do_compose(widget);
                get_window_action(ACTION_FIND_IN_CONVERSATION).set_enabled(false);
            } else {
                main_window.conversation_viewer.do_compose_embedded(
                    widget,
                    referred,
                    is_draft
                );
            }
        } else {
            new ComposerWindow(widget);
            widget.state = ComposerWidget.ComposerState.DETACHED;
        }

        // Load the widget's content
        Geary.Email? full = null;
        if (referred != null) {
            try {
                full = yield get_store_for_folder(current_folder).fetch_email_async(
                    referred.id, Geary.ComposedEmail.REQUIRED_REPLY_FIELDS,
                    Geary.Folder.ListFlags.NONE, cancellable_folder);
            } catch (Error e) {
                message("Could not load full message: %s", e.message);
            }
        }
        yield widget.load(full, quote, is_draft);

        widget.set_focus();
    }

    private bool should_create_new_composer(ComposerWidget.ComposeType? compose_type,
        Geary.Email? referred, string? quote, bool is_draft, out bool inline) {
        inline = true;
        
        // In we're replying, see whether we already have a reply for that message.
        if (compose_type != null && compose_type != ComposerWidget.ComposeType.NEW_MESSAGE) {
            foreach (ComposerWidget cw in composer_widgets) {
                if (cw.state != ComposerWidget.ComposerState.DETACHED &&
                    ((referred != null && cw.referred_ids.contains(referred.id)) ||
                     quote != null)) {
                    cw.change_compose_type(compose_type, referred, quote);
                    return false;
                }
            }
            inline = !any_inline_composers();
            return true;
        }
        
        // If there are no inline composers, go ahead!
        if (!any_inline_composers())
            return true;
        
        // If we're resuming a draft with open composers, open in a new window.
        if (is_draft) {
            inline = false;
            return true;
        }
        
        // If we're creating a new message, and there's already a new message open, focus on
        // it if it hasn't been modified; otherwise open a new composer in a new window.
        if (compose_type == ComposerWidget.ComposeType.NEW_MESSAGE) {
            foreach (ComposerWidget cw in composer_widgets) {
                if (cw.state == ComposerWidget.ComposerState.PANED) {
                    if (!cw.is_blank) {
                        inline = false;
                        return true;
                    } else {
                        cw.change_compose_type(compose_type);  // To refocus
                        return false;
                    }
                }
            }
        }
        
        // Find out what to do with the inline composers.
        // TODO: Remove this in favor of automatically saving drafts
        this.application.present();
        Gee.List<ComposerWidget> composers_to_destroy = new Gee.ArrayList<ComposerWidget>();
        foreach (ComposerWidget cw in composer_widgets) {
            if (cw.state != ComposerWidget.ComposerState.DETACHED)
                composers_to_destroy.add(cw);
        }
        string message = ngettext(
            "Close the draft message?",
            "Close all draft messages?",
            composers_to_destroy.size
        );
        ConfirmationDialog dialog = new ConfirmationDialog(
            main_window, message, null, Stock._CLOSE, "destructive-action"
        );
        if (dialog.run() == Gtk.ResponseType.OK) {
            foreach(ComposerWidget cw in composers_to_destroy)
                ((ComposerContainer) cw.parent).close_container();
            return true;
        }
        return false;
    }
    
    public bool can_switch_conversation_view() {
        bool inline;
        return should_create_new_composer(null, null, null, false, out inline);
    }
    
    public bool any_inline_composers() {
        foreach (ComposerWidget cw in composer_widgets)
            if (cw.state != ComposerWidget.ComposerState.DETACHED)
                return true;
        return false;
    }
    
    private void on_composer_widget_destroy(Gtk.Widget sender) {
        composer_widgets.remove((ComposerWidget) sender);
        debug(@"Destroying composer of type $(((ComposerWidget) sender).compose_type); "
            + @"$(composer_widgets.size) composers remaining");
        
        if (waiting_to_close.remove((ComposerWidget) sender)) {
            // If we just removed the last window in the waiting to close list, it's time to exit!
            if (waiting_to_close.size == 0)
                this.application.exit();
        }
    }
    
    private void on_new_message(SimpleAction? action) {
        create_compose_widget(ComposerWidget.ComposeType.NEW_MESSAGE);
    }

    private void on_reply_to_message(ConversationEmail target_view) {
        create_reply_forward_widget(ComposerWidget.ComposeType.REPLY, target_view);
    }

    private void on_reply_to_message_action(SimpleAction action) {
        create_reply_forward_widget(ComposerWidget.ComposeType.REPLY, null);
    }

    private void on_reply_all_message(ConversationEmail target_view) {
        create_reply_forward_widget(ComposerWidget.ComposeType.REPLY_ALL, target_view);
    }

    private void on_reply_all_message_action(SimpleAction action) {
        create_reply_forward_widget(ComposerWidget.ComposeType.REPLY_ALL, null);
    }

    private void on_forward_message(ConversationEmail target_view) {
        create_reply_forward_widget(ComposerWidget.ComposeType.FORWARD, target_view);
    }

    private void on_forward_message_action(SimpleAction action) {
        create_reply_forward_widget(ComposerWidget.ComposeType.FORWARD, null);
    }

    private void on_find_in_conversation_action(SimpleAction action) {
        this.main_window.conversation_viewer.conversation_find_bar.set_search_mode(true);
    }

    private void on_search_activated(SimpleAction action) {
        show_search_bar();
    }

    private void on_archive_conversation(SimpleAction action) {
        archive_or_delete_selection_async.begin(true, false, cancellable_folder,
            on_archive_or_delete_selection_finished);
    }

    private void on_trash_conversation(SimpleAction action) {
        archive_or_delete_selection_async.begin(false, true, cancellable_folder,
            on_archive_or_delete_selection_finished);
    }

    private void on_delete_conversation(SimpleAction action) {
        archive_or_delete_selection_async.begin(false, false, cancellable_folder,
            on_archive_or_delete_selection_finished);
    }

    private void on_empty_spam(SimpleAction action) {
        on_empty_trash_or_spam(Geary.SpecialFolderType.SPAM);
    }

    private void on_empty_trash(SimpleAction action) {
        on_empty_trash_or_spam(Geary.SpecialFolderType.TRASH);
    }

    private void on_empty_trash_or_spam(Geary.SpecialFolderType special_folder_type) {
        // Account must be in place, must have the specified special folder type, and that folder
        // must support Empty in order for this command to proceed
        if (current_account == null)
            return;
        
        Geary.Folder? folder = null;
        try {
            folder = current_account.get_special_folder(special_folder_type);
        } catch (Error err) {
            debug("%s: Unable to get special folder %s: %s", current_account.to_string(),
                special_folder_type.to_string(), err.message);
            
            // fall through
        }
        
        if (folder == null)
            return;
        
        Geary.FolderSupport.Empty? emptyable = folder as Geary.FolderSupport.Empty;
        if (emptyable == null) {
            debug("%s: Special folder %s (%s) does not support emptying", current_account.to_string(),
                folder.path.to_string(), special_folder_type.to_string());
            
            return;
        }
        
        ConfirmationDialog dialog = new ConfirmationDialog(main_window,
            _("Empty all email from your %s folder?").printf(special_folder_type.get_display_name()),
            _("This removes the email from Geary and your email server.")
                + "  <b>" + _("This cannot be undone.") + "</b>",
            _("Empty %s").printf(special_folder_type.get_display_name()), "destructive-action");
        dialog.use_secondary_markup(true);
        dialog.set_focus_response(Gtk.ResponseType.CANCEL);
        
        if (dialog.run() == Gtk.ResponseType.OK)
            empty_folder_async.begin(emptyable, cancellable_folder);
    }
    
    private async void empty_folder_async(Geary.FolderSupport.Empty emptyable, Cancellable? cancellable) {
        try {
            yield do_empty_folder_async(emptyable, cancellable);
        } catch (Error err) {
            // don't report to user if cancelled
            if (cancellable is IOError.CANCELLED)
                return;
            
            ErrorDialog dialog = new ErrorDialog(main_window,
                _("Error emptying %s").printf(emptyable.get_display_name()), err.message);
            dialog.run();
        }
    }

    private async void do_empty_folder_async(Geary.FolderSupport.Empty emptyable, Cancellable? cancellable)
        throws Error {
        bool open = false;
        try {
            yield emptyable.open_async(Geary.Folder.OpenFlags.NO_DELAY, cancellable);
            open = true;
            yield emptyable.empty_folder_async(cancellable);
        } finally {
            if (open) {
                try {
                    yield emptyable.close_async(null);
                } catch (Error err) {
                    // ignored
                }
            }
        }
    }

    private bool current_folder_supports_trash() {
        return (current_folder != null && current_folder.special_folder_type != Geary.SpecialFolderType.TRASH
            && !current_folder.properties.is_local_only && current_account != null
            && (current_folder as Geary.FolderSupport.Move) != null);
    }

    private bool confirm_delete(int num_messages) {
        this.application.present();
        ConfirmationDialog dialog = new ConfirmationDialog(main_window, ngettext(
            "Do you want to permanently delete this message?",
            "Do you want to permanently delete these messages?", num_messages),
            null, _("Delete"), "destructive-action");

        return (dialog.run() == Gtk.ResponseType.OK);
    }

    private async void trash_messages_async(Gee.Collection<Geary.EmailIdentifier> ids, Cancellable? cancellable)
            throws Error {
        debug("Trashing selected messages");

        Geary.FolderSupport.Move? supports_move = current_folder as Geary.FolderSupport.Move;
        if (current_folder_supports_trash() && supports_move != null) {
            Geary.FolderPath trash_path = (yield current_account.get_required_special_folder_async(
                Geary.SpecialFolderType.TRASH, cancellable)).path;
            save_revokable(yield supports_move.move_email_async(ids, trash_path, cancellable),
                _("Undo trash (Ctrl+Z)"));
        } else {
            debug("Folder %s doesn't support move or account %s doesn't have a trash folder",
                current_folder.to_string(), current_account.to_string());
        }
    }

    private async void delete_messages_async(Gee.Collection<Geary.EmailIdentifier> ids, Cancellable? cancellable)
            throws Error {
        debug("Deleting selected messages");

        Geary.FolderSupport.Remove? supports_remove = current_folder as Geary.FolderSupport.Remove;
        if (supports_remove != null) {
            if (confirm_delete(ids.size)) {
                yield supports_remove.remove_email_async(ids, cancellable);
            } else {
                last_deleted_conversation = null;
            }
        } else {
            debug("Folder %s doesn't support remove", current_folder.to_string());
        }
    }

    private async void archive_or_delete_selection_async(bool archive, bool trash,
        Cancellable? cancellable) throws Error {
        if (!can_switch_conversation_view())
            return;

        ConversationListBox list_view =
            main_window.conversation_viewer.current_list;
        if (list_view != null &&
            list_view.conversation == last_deleted_conversation) {
            debug("Not archiving/trashing/deleting; viewed conversation is last deleted conversation");
            return;
        }

        selection_operation_started();

        last_deleted_conversation = selected_conversations.size > 0
            ? Geary.traverse<Geary.App.Conversation>(selected_conversations).first() : null;

        Gee.Collection<Geary.EmailIdentifier> ids = get_selected_email_ids(false);
        if (archive) {
            debug("Archiving selected messages");
            
            Geary.FolderSupport.Archive? supports_archive = current_folder as Geary.FolderSupport.Archive;
            if (supports_archive == null) {
                debug("Folder %s doesn't support archive", current_folder.to_string());
            } else {
                save_revokable(yield supports_archive.archive_email_async(ids, cancellable),
                    _("Undo archive (Ctrl+Z)"));
            }
            
            return;
        }
        
        if (trash) {
            yield trash_messages_async(ids, cancellable);
        } else {
            yield delete_messages_async(ids, cancellable);
        }
    }

    private void on_archive_or_delete_selection_finished(Object? source, AsyncResult result) {
        try {
            archive_or_delete_selection_async.end(result);
        } catch (Error e) {
            debug("Unable to archive/trash/delete messages: %s", e.message);
        }
        selection_operation_finished();
    }

    private void save_revokable(Geary.Revokable? new_revokable, string? description) {
        // disconnect old revokable & blindly commit it
        if (revokable != null) {
            revokable.notify[Geary.Revokable.PROP_VALID].disconnect(on_revokable_valid_changed);
            revokable.notify[Geary.Revokable.PROP_IN_PROCESS].disconnect(update_revokable_action);
            revokable.committed.disconnect(on_revokable_committed);
            
            revokable.commit_async.begin();
        }
        
        // store new revokable
        revokable = new_revokable;
        
        // connect to new revokable
        if (revokable != null) {
            revokable.notify[Geary.Revokable.PROP_VALID].connect(on_revokable_valid_changed);
            revokable.notify[Geary.Revokable.PROP_IN_PROCESS].connect(update_revokable_action);
            revokable.committed.connect(on_revokable_committed);
        }

        if (revokable != null && description != null)
            this.main_window.main_toolbar.undo_tooltip = description;
        else
            this.main_window.main_toolbar.undo_tooltip = _("Undo (Ctrl+Z)");

        update_revokable_action();
    }

    private void update_revokable_action() {
        get_window_action(ACTION_UNDO).set_enabled(this.revokable != null && this.revokable.valid && !this.revokable.in_process);
    }

    private void on_revokable_valid_changed() {
        // remove revokable if it goes invalid
        if (revokable != null && !revokable.valid)
            save_revokable(null, null);
    }
    
    private void on_revokable_committed(Geary.Revokable? committed_revokable) {
        if (committed_revokable == null)
            return;

        // use existing description
        save_revokable(committed_revokable, this.main_window.main_toolbar.undo_tooltip);
    }

    private void on_revoke() {
        if (revokable != null && revokable.valid)
            revokable.revoke_async.begin(null, on_revoke_completed);
    }
    
    private void on_revoke_completed(Object? object, AsyncResult result) {
        // Don't use the "revokable" instance because it might have gone null before this callback
        // was reached
        Geary.Revokable? origin = object as Geary.Revokable;
        if (origin == null)
            return;
        
        try {
            origin.revoke_async.end(result);
        } catch (Error err) {
            debug("Unable to revoke operation: %s", err.message);
        }
    }

    private void selection_operation_started() {
        this.operation_count += 1;
        if (this.operation_count == 1) {
            this.main_window.conversation_list_view.set_changing_selection(true);
        }
    }

    private void selection_operation_finished() {
        this.operation_count -= 1;
        if (this.operation_count == 0) {
            this.main_window.conversation_list_view.set_changing_selection(false);
        }
    }

    private void on_zoom(SimpleAction action, Variant? parameter) {
        ConversationListBox? view = main_window.conversation_viewer.current_list;
        if (view != null && parameter != null) {
            string zoom_action = parameter.get_string();
            if (zoom_action == "in")
                view.zoom_in();
            else if (zoom_action == "out")
                view.zoom_out();
            else
                view.zoom_reset();
        }
    }

    private void on_conversation_list() {
        this.main_window.conversation_list_view.grab_focus();
    }

    private void on_sent(Geary.RFC822.Message rfc822) {
        // Translators: The label for an in-app notification. The
        // string substitution is a list of recipients of the email.
        string message = _(
            "Successfully sent mail to %s."
        ).printf(EmailUtil.to_short_recipient_display(rfc822.to));
        InAppNotification notification = new InAppNotification(message);
        this.main_window.add_notification(notification);
        Libnotify.play_sound("message-sent-email");
    }

    private void on_conversation_view_added(ConversationListBox list) {
        list.email_added.connect(on_conversation_viewer_email_added);
        list.mark_emails.connect(on_conversation_viewer_mark_emails);
    }

    private void on_conversation_viewer_email_added(ConversationEmail view) {
        view.attachments_activated.connect(on_attachments_activated);
        view.reply_to_message.connect(on_reply_to_message);
        view.reply_all_message.connect(on_reply_all_message);
        view.forward_message.connect(on_forward_message);

        Geary.App.Conversation conversation = main_window.conversation_viewer.current_list.conversation;
        bool in_current_folder = (conversation.is_in_base_folder(view.email.id) &&
            conversation.base_folder == current_folder);
        bool supports_trash = in_current_folder && current_folder_supports_trash();
        bool supports_delete = in_current_folder && current_folder is Geary.FolderSupport.Remove;
        view.trash_message.connect(on_trash_message);
        view.delete_message.connect(on_delete_message);
        view.set_folder_actions_enabled(supports_trash, supports_delete);
        main_window.on_shift_key.connect(view.shift_key_changed);

        view.edit_draft.connect((draft_view) => {
                create_compose_widget(
                    ComposerWidget.ComposeType.NEW_MESSAGE,
                    draft_view.email, null, null, true
                );
            });
        foreach (ConversationMessage msg_view in view) {
            msg_view.link_activated.connect(on_link_activated);
            msg_view.save_image.connect((url, alt_text, buf) => {
                    on_save_image_extended(view, url, alt_text, buf);
                });
            msg_view.search_activated.connect((op, value) => {
                    string search = op + ":" + value;
                    show_search_bar(search);
                });
        }
        view.save_attachments.connect(on_save_attachments);
        view.view_source.connect(on_view_source);
    }

    private void on_trash_message(ConversationEmail target_view) {
        Gee.Collection<Geary.EmailIdentifier> ids =
            new Gee.ArrayList<Geary.EmailIdentifier>();
        ids.add(target_view.email.id);
        trash_messages_async.begin(ids, cancellable_folder);
    }

    private void on_delete_message(ConversationEmail target_view) {
        Gee.Collection<Geary.EmailIdentifier> ids =
            new Gee.ArrayList<Geary.EmailIdentifier>();
        ids.add(target_view.email.id);
        delete_messages_async.begin(ids, cancellable_folder);
    }

    private void on_view_source(ConversationEmail email_view) {
        string source = (email_view.email.header.buffer.to_string() +
                         email_view.email.body.buffer.to_string());
        string temporary_filename;
        try {
            int temporary_handle = FileUtils.open_tmp("geary-message-XXXXXX.txt",
                                                      out temporary_filename);
            FileUtils.set_contents(temporary_filename, source);
            FileUtils.close(temporary_handle);

            // ensure this file is only readable by the user ... this
            // needs to be done after the file is closed
            FileUtils.chmod(temporary_filename, (int) (Posix.S_IRUSR | Posix.S_IWUSR));

            string temporary_uri = Filename.to_uri(temporary_filename, null);
            this.application.show_uri(temporary_uri);
        } catch (Error error) {
            ErrorDialog dialog = new ErrorDialog(
                main_window,
                _("Failed to open default text editor."),
                error.message
            );
            dialog.run();
        }
    }

    private SimpleAction get_window_action(string action_name) {
        return (SimpleAction) this.main_window.lookup_action(action_name);
    }

    // Disables all single-message buttons and enables all multi-message buttons.
    public void enable_multiple_message_buttons() {
        main_window.main_toolbar.selected_conversations = this.selected_conversations.size;

        // Single message only buttons.
        get_window_action(ACTION_REPLY_TO_MESSAGE).set_enabled(false);
        get_window_action(ACTION_REPLY_ALL_MESSAGE).set_enabled(false);
        get_window_action(ACTION_FORWARD_MESSAGE).set_enabled(false);

        // Mutliple message buttons.
        get_window_action(ACTION_MOVE_MENU).set_enabled(current_folder is Geary.FolderSupport.Move);
        get_window_action(ACTION_ARCHIVE_CONVERSATION).set_enabled(current_folder is Geary.FolderSupport.Archive);
        get_window_action(ACTION_TRASH_CONVERSATION).set_enabled(current_folder_supports_trash());
        get_window_action(ACTION_DELETE_CONVERSATION).set_enabled(current_folder is Geary.FolderSupport.Remove);

        cancel_context_dependent_buttons();
        enable_context_dependent_buttons_async.begin(true, cancellable_context_dependent_buttons);
    }

    // Enables or disables the message buttons on the toolbar.
    public void enable_message_buttons(bool sensitive) {
        main_window.main_toolbar.selected_conversations = this.selected_conversations.size;

        // No reply/forward in drafts folder.
        bool respond_sensitive = sensitive;
        if (current_folder != null && current_folder.special_folder_type == Geary.SpecialFolderType.DRAFTS)
            respond_sensitive = false;

        get_window_action(ACTION_REPLY_TO_MESSAGE).set_enabled(respond_sensitive);
        get_window_action(ACTION_REPLY_ALL_MESSAGE).set_enabled(respond_sensitive);
        get_window_action(ACTION_FORWARD_MESSAGE).set_enabled(respond_sensitive);
        get_window_action(ACTION_MOVE_MENU).set_enabled(sensitive && (current_folder is Geary.FolderSupport.Move));
        get_window_action(ACTION_ARCHIVE_CONVERSATION).set_enabled(sensitive && (current_folder is Geary.FolderSupport.Archive));
        get_window_action(ACTION_TRASH_CONVERSATION).set_enabled(sensitive && current_folder_supports_trash());
        get_window_action(ACTION_DELETE_CONVERSATION).set_enabled(sensitive && (current_folder is Geary.FolderSupport.Remove));

        cancel_context_dependent_buttons();
        enable_context_dependent_buttons_async.begin(sensitive, cancellable_context_dependent_buttons);
    }

    private async void enable_context_dependent_buttons_async(bool sensitive, Cancellable? cancellable) {
        Gee.MultiMap<Geary.EmailIdentifier, Type>? selected_operations = null;
        try {
            if (current_folder != null) {
                Geary.App.EmailStore? store = get_store_for_folder(current_folder);
                if (store != null) {
                    selected_operations = yield store
                        .get_supported_operations_async(get_selected_email_ids(false), cancellable);
                }
            }
        } catch (Error e) {
            debug("Error checking for what operations are supported in the selected conversations: %s",
                e.message);
        }
        
        // Exit here if the user has cancelled.
        if (cancellable != null && cancellable.is_cancelled())
            return;
        
        Gee.HashSet<Type> supported_operations = new Gee.HashSet<Type>();
        if (selected_operations != null)
            supported_operations.add_all(selected_operations.get_values());

        get_window_action(ACTION_SHOW_MARK_MENU).set_enabled(sensitive && (typeof(Geary.FolderSupport.Mark) in supported_operations));
        get_window_action(ACTION_COPY_MENU).set_enabled(sensitive && (supported_operations.contains(typeof(Geary.FolderSupport.Copy))));
    }

    // Returns a list of composer windows for an account, or null if none.
    public Gee.List<ComposerWidget>? get_composer_widgets_for_account(Geary.AccountInformation account) {
        Gee.LinkedList<ComposerWidget> ret = Geary.traverse<ComposerWidget>(composer_widgets)
            .filter(w => w.account.information == account)
            .to_linked_list();
        
        return ret.size >= 1 ? ret : null;
    }

    private void show_search_bar(string? text = null) {
        main_window.search_bar.give_search_focus();
        if (text != null) {
            main_window.search_bar.set_search_text(text);
        }
    }

    private void do_search(string search_text) {
        Geary.SearchFolder? search_folder = null;
        if (this.current_account != null) {
            try {
                search_folder =
                    this.current_account.get_special_folder(
                        Geary.SpecialFolderType.SEARCH
                    ) as Geary.SearchFolder;
            } catch (Error e) {
                debug("Could not get search folder: %s", e.message);
            }
        }

        if (Geary.String.is_empty_or_whitespace(search_text)) {
            if (this.previous_non_search_folder != null &&
                this.current_folder is Geary.SearchFolder) {
                this.main_window.folder_list.select_folder(
                    this.previous_non_search_folder
                );
            }

            this.main_window.folder_list.remove_search();

            if (search_folder !=  null) {
                search_folder.clear();
            }
        } else if (search_folder != null) {
            cancel_search(); // Stop any search in progress

            search_folder.search(
                search_text,
                this.application.config.get_search_strategy(),
                this.cancellable_search
            );

            this.main_window.folder_list.set_search(search_folder);
        }

        search_text_changed(search_text);
    }

    /**
     * Returns a read-only set of currently selected conversations.
     */
    public Gee.Set<Geary.App.Conversation> get_selected_conversations() {
        return selected_conversations.read_only_view;
    }

    private static void get_gcr_params(Geary.Endpoint endpoint, out Gcr.Certificate cert,
        out string peer) {
        cert = new Gcr.SimpleCertificate(endpoint.untrusted_certificate.certificate.data);
        peer = "%s:%u".printf(endpoint.remote_address.hostname, endpoint.remote_address.port);
    }

    private inline Geary.App.EmailStore get_store_for_folder(Geary.Folder target) {
        return this.accounts.get(target.account.information).store;
    }

    private void on_account_available(Geary.AccountInformation info) {
        Geary.Account? account = null;
        try {
            account = Geary.Engine.instance.get_account_instance(info);
        } catch (Error e) {
            error("Error creating account instance: %s", e.message);
        }

        if (account != null) {
            upgrade_dialog.add_account(account, cancellable_open_account);
            open_account(account);
        }
    }

    private void on_account_added(Geary.AccountInformation added,
                                  AccountManager.Status status) {
        if (status == AccountManager.Status.ENABLED) {
            try {
                this.application.engine.add_account(added);
            } catch (GLib.Error err) {
                report_problem(
                    new Geary.AccountProblemReport(
                        Geary.ProblemType.GENERIC_ERROR, added, err
                    )
                );
            }
        }
    }

    private void on_account_status_changed(Geary.AccountInformation changed,
                                           AccountManager.Status status) {
        switch (status) {
        case AccountManager.Status.ENABLED:
            if (!this.application.engine.has_account(changed.id)) {
                try {
                    this.application.engine.add_account(changed);
                } catch (GLib.Error err) {
                    report_problem(
                        new Geary.AccountProblemReport(
                            Geary.ProblemType.GENERIC_ERROR, changed, err
                        )
                    );
                }
            }
            break;

        case AccountManager.Status.UNAVAILABLE:
        case AccountManager.Status.DISABLED:
            if (this.application.engine.has_account(changed.id)) {
                this.close_account.begin(
                    changed,
                    (obj, res) => {
                        this.close_account.end(res);
                        try {
                            this.application.engine.remove_account(changed);
                        } catch (GLib.Error err) {
                            report_problem(
                                new Geary.AccountProblemReport(
                                    Geary.ProblemType.GENERIC_ERROR,
                                    changed,
                                    err
                                )
                            );
                        }
                    }
                );
            }
            break;
        }
    }

    private void on_scan_completed() {
        // Done scanning.  Check if we have enough messages to fill
        // the conversation list; if not, trigger a load_more();
        if (!main_window.conversation_list_has_scrollbar()) {
            debug("Not enough messages, loading more for folder %s", current_folder.to_string());
            on_load_more();
        }
    }

    private void on_scan_error(Geary.App.ConversationMonitor monitor, Error err) {
        // XXX determine the problem better here
        Geary.AccountInformation account =
            monitor.base_folder.account.information;
        report_problem(
            new Geary.ServiceProblemReport(
                Geary.ProblemType.GENERIC_ERROR,
                account,
                account.imap,
                err
            )
        );
    }

    private void on_account_unavailable(Geary.AccountInformation info) {
        this.close_account.begin(info);
    }

    private void on_save_attachments(Gee.Collection<Geary.Attachment> attachments) {
        GLib.Cancellable? cancellable = null;
        if (this.current_account != null) {
            cancellable = this.accounts.get(
                this.current_account.information
            ).cancellable;
        }
        if (attachments.size == 1) {
            this.save_attachment_to_file.begin(
                attachments.to_array()[0], null, cancellable
            );
        } else {
            this.save_attachments_to_file.begin(attachments, cancellable);
        }
    }

    private void on_link_activated(string uri) {
        if (uri.down().has_prefix(Geary.ComposedEmail.MAILTO_SCHEME)) {
            compose_mailto(uri);
        } else {
            open_uri(uri);
        }
    }

    private void on_save_image_extended(ConversationEmail view,
                                        string url,
                                        string? alt_text,
                                        Geary.Memory.Buffer resource_buf) {
        GLib.Cancellable? cancellable = null;
        if (this.current_account != null) {
            cancellable = this.accounts.get(
                this.current_account.information
            ).cancellable;
        }

        // This is going to be either an inline image, or a remote
        // image, so either treat it as an attachment ot assume we'll
        // have a valid filename in the URL
        bool handled = false;
        if (url.has_prefix(ClientWebView.CID_URL_PREFIX)) {
            string cid = url.substring(ClientWebView.CID_URL_PREFIX.length);
            Geary.Attachment? attachment = null;
            try {
                attachment = view.email.get_attachment_by_content_id(cid);
            } catch (Error err) {
                debug("Could not get attachment \"%s\": %s", cid, err.message);
            }
            if (attachment != null) {
                this.save_attachment_to_file.begin(
                    attachment, alt_text, cancellable
                );
                handled = true;
            }
        }

        if (!handled) {
            GLib.File source = GLib.File.new_for_uri(url);
            // Querying the URL-based file for the display name
            // results in it being looked up, so just get the basename
            // from it directly. GIO seems to decode any %-encoded
            // chars anyway.
            string? display_name = source.get_basename();
            if (Geary.String.is_empty_or_whitespace(display_name)) {
                display_name = GearyController.untitled_file_name;
            }

            this.prompt_save_buffer.begin(
                display_name, resource_buf, cancellable
            );
        }
    }

}
